module Saci
  module Record
    # ActiveModel::Dirty-compatible change tracking for `Record::Base`
    # (G10). Reopened from `base.cr` so the core class stays readable.
    #
    # Snapshot model:
    # * `@__saci_dirty_original` holds the values at load/create/save time.
    # * `@__saci_dirty_changes` holds `{old, new}` for attributes differing
    #   from that snapshot.
    # * `@__saci_previous_changes` holds what the last successful save
    #   persisted; it survives until the next save and is cleared by
    #   `reload` (Rails semantics).
    #
    # Failed validations/saves leave both maps untouched (no commit).
    class Base
      # Value at the last load/create/save per column.
      @__saci_dirty_original : Hash(String, Value) = {} of String => Value

      # Current changes: name => [old, new].
      @__saci_dirty_changes : Hash(String, Array(Value)) = {} of String => Array(Value)

      # Changes committed by the last successful save.
      @__saci_previous_changes : Hash(String, Array(Value)) = {} of String => Array(Value)

      # Attributes explicitly written since the last load/save. Used by
      # G299 to decide whether `updated_at` may be auto-bumped on update.
      @__saci_assigned_for_save : Set(String) = Set(String).new

      # `previously_new_record?` state (true after a create, until reload
      # or the next save).
      @__saci_previously_new_record : Bool = false

      def changed? : Bool
        !@__saci_dirty_changes.empty?
      end

      def changed : Array(String)
        @__saci_dirty_changes.keys
      end

      # Old value per changed attribute (`{"title" => "old"}`).
      def changed_attributes : Hash(String, Value)
        h = {} of String => Value
        @__saci_dirty_changes.each { |name, pair| h[name] = pair[0] }
        h
      end

      # `{name => [old, new]}` for the current (unsaved) changes.
      def changes : Hash(String, Array(Value))
        __saci_changes_snapshot
      end

      # Same as `changes` (Rails alias).
      def changes_to_save : Hash(String, Array(Value))
        changes
      end

      def has_changes_to_save? : Bool
        changed?
      end

      # `{name => [old, new]}` persisted by the last successful save.
      def previous_changes : Hash(String, Array(Value))
        h = {} of String => Array(Value)
        @__saci_previous_changes.each { |name, pair| h[name] = pair.dup }
        h
      end

      def saved_changes : Hash(String, Array(Value))
        previous_changes
      end

      def saved_changes? : Bool
        !@__saci_previous_changes.empty?
      end

      # Value of `name` before the last save (falls back to the current
      # value when the attribute was not part of `previous_changes`).
      def attribute_before_last_save(name : String | Symbol) : Value
        __saci_attribute_previously_was(name.to_s)
      end

      # Rails `attribute_was` / `attribute_previously_was` aliases.
      def attribute_was(name : String | Symbol) : Value
        __saci_attribute_was(name.to_s)
      end

      def attribute_previously_was(name : String | Symbol) : Value
        __saci_attribute_previously_was(name.to_s)
      end

      # `true` when the record was created by the last save (Rails 7).
      def previously_new_record? : Bool
        @__saci_previously_new_record
      end

      # `true` when the record existed before the last save (updated, not
      # created) and is still persisted.
      def previously_persisted? : Bool
        persisted? && !@__saci_previously_new_record
      end

      def __saci_attribute_changed?(name : String) : Bool
        @__saci_dirty_changes.has_key?(name)
      end

      def __saci_attribute_change(name : String) : Array(Value)?
        @__saci_dirty_changes[name]?.try(&.dup)
      end

      def __saci_attribute_was(name : String) : Value
        if pair = @__saci_dirty_changes[name]?
          pair[0]
        elsif @__saci_dirty_original.has_key?(name)
          @__saci_dirty_original[name]
        else
          __saci_get_attr(name)
        end
      end

      def __saci_attribute_previously_was(name : String) : Value
        if pair = @__saci_previous_changes[name]?
          pair[0]
        else
          __saci_get_attr(name)
        end
      end

      def __saci_saved_change_to(name : String) : Array(Value)?
        @__saci_previous_changes[name]?.try(&.dup)
      end

      def __saci_saved_change_to?(name : String) : Bool
        @__saci_previous_changes.has_key?(name)
      end

      def __saci_will_save_change_to?(name : String) : Bool
        __saci_attribute_changed?(name)
      end

      # Called by every column setter (and `__saci_set_attr`).
      def __saci_track_write(name : String, old_value : Value, new_value : Value) : Nil
        @__saci_assigned_for_save << name
        unless @__saci_dirty_original.has_key?(name)
          # Defensive fallback for objects constructed outside the normal
          # initializer path: the pre-write value becomes the snapshot.
          @__saci_dirty_original[name] = old_value
        end
        original = @__saci_dirty_original[name]
        if __saci_values_equal?(original, new_value)
          @__saci_dirty_changes.delete(name)
        else
          @__saci_dirty_changes[name] = [original, new_value] of Value
        end
      end

      def __saci_changes_snapshot : Hash(String, Array(Value))
        h = {} of String => Array(Value)
        @__saci_dirty_changes.each { |name, pair| h[name] = pair.dup }
        h
      end

      def __saci_snapshot_values : Hash(String, Value)
        h = {} of String => Value
        self.class.__saci_column_names.each do |(name, _)|
          h[name] = __saci_get_attr(name)
        end
        h
      end

      # Clears dirty state and `previous_changes`; snapshots current values.
      # Called after load, `reload`, and from the constructors (with
      # defaults applied, before mass assignment).
      def __saci_dirty_reset! : Nil
        @__saci_dirty_original = __saci_snapshot_values
        @__saci_dirty_changes.clear
        @__saci_previous_changes.clear
        @__saci_assigned_for_save.clear
        @__saci_previously_new_record = false
      end

      # Commits dirty state after a successful insert/update. `pre_values`
      # is a full snapshot taken just before the SQL write; `pre_changes`
      # is the dirty map at the same point (so pre-save mutations are
      # included). Values changed by the database (autoincrement id,
      # timestamps) are added from the diff.
      def __saci_dirty_commit!(pre_values : Hash(String, Value), pre_changes : Hash(String, Array(Value)), was_new : Bool) : Nil
        previous = {} of String => Array(Value)
        pre_changes.each { |name, pair| previous[name] = pair.dup }
        current = __saci_snapshot_values
        self.class.__saci_column_names.each do |(name, _)|
          old = pre_values[name]?
          new = current[name]
          unless __saci_values_equal?(old, new)
            previous[name] = [old, new] of Value unless previous.has_key?(name)
          end
        end
        @__saci_previous_changes = previous
        @__saci_dirty_original = current
        @__saci_dirty_changes.clear
        @__saci_assigned_for_save.clear
        @__saci_previously_new_record = was_new
      end

      # Direct writes (`update_column`, `update_columns`, `touch`) leave
      # the in-memory value and the database in sync.
      def __saci_mark_attribute_clean(name : String) : Nil
        @__saci_dirty_original[name] = __saci_get_attr(name)
        @__saci_dirty_changes.delete(name)
        @__saci_assigned_for_save.delete(name)
      end

      private def __saci_values_equal?(a : Value, b : Value) : Bool
        return true if a.nil? && b.nil?
        return false if a.nil? || b.nil?
        a == b
      end
    end
  end
end
