require "./blob"

module Saci
  module Storage
    # Join row between an application record and a `Blob`
    # (ActiveStorage::Attachment). The polymorphic pair
    # `record_type` / `record_id` plus `name` is unique by convention.
    #
    # ```
    # create_table :active_storage_attachments do |t|
    #   t.string :record_type, null: false
    #   t.bigint :record_id, null: false
    #   t.string :name, null: false
    #   t.bigint :blob_id, null: false
    #   t.datetime :created_at
    # end
    # ```
    class Attachment < Saci::Record::Base
      table "active_storage_attachments"

      column id : Int64, primary: true
      column record_type : String
      column record_id : Int64
      column name : String
      column blob_id : Int64
      column created_at : Time

      before_validation :__saci_stamp_created_at, on: :create

      private def __saci_stamp_created_at : Nil
        self.created_at = Time.utc if created_at.nil?
      end

      def blob : Blob?
        current_id = blob_id
        current_id.nil? ? nil : Blob.find_by(id: current_id)
      end

      # Resolves the owner through the polymorphic registry. A deleted
      # owner yields nil instead of raising.
      def record : Saci::Record::Base?
        type = record_type
        current_id = record_id
        return nil if type.nil? || current_id.nil?
        Saci::Record.resolve_polymorphic(type, current_id)
      rescue Saci::Record::RecordNotFound
        nil
      end

      # Deletes this join row; the blob is purged only when no other
      # attachment references it.
      def purge : Nil
        target = blob
        destroy unless new_record?
        target.try(&.purge_if_unattached)
        nil
      end

      def purge_later : Nil
        if current_id = id
          AttachmentPurgeJob.perform_later({"attachment_id" => current_id})
        else
          purge
        end
        nil
      end

      # Finds the current attachment for a polymorphic owner/name.
      def self.find_for(record : Saci::Record::Base, name : String | Symbol) : Attachment?
        owner_type, owner_id = owner_key(record)
        where(record_type: owner_type, record_id: owner_id, name: name.to_s).order(:id).first?
      end

      def self.all_for(record : Saci::Record::Base, name : String | Symbol) : Array(Attachment)
        owner_type, owner_id = owner_key(record)
        where(record_type: owner_type, record_id: owner_id, name: name.to_s).order(:id).to_a
      end

      # Creates the join row (validates that the owner/blob are persisted).
      def self.attach(record : Saci::Record::Base, name : String | Symbol, blob : Blob) : Attachment
        owner_type, owner_id = owner_key(record)
        blob_id_value = blob.id || raise Saci::Record::RecordNotSaved.new("cannot attach an unsaved blob")
        attachment = new(
          record_type: owner_type,
          record_id: owner_id,
          name: name.to_s,
          blob_id: blob_id_value,
          created_at: Time.utc
        )
        attachment.save!
        attachment
      end

      private def self.owner_key(record : Saci::Record::Base) : Tuple(String, Int64)
        raise Saci::Record::RecordNotSaved.new("cannot attach to an unsaved #{record.class}") unless record.persisted?
        pk = record.__saci_get_attr(record.class.__saci_primary_key)
        id = pk.nil? ? nil : Saci::Record.to_i64(pk)
        raise Saci::Record::RecordNotSaved.new("cannot attach to #{record.class} without a numeric primary key") if id.nil?
        {record.class.name, id}
      end
    end
  end
end
