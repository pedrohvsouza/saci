module Saci
  module CLI
    # `saci destroy KIND NAME` — inverse of the generators (G115).
    #
    # Safety rules (documented because Rails' destroy is unconditional):
    # * only files the matching generator owns are considered;
    # * a file whose content differs from what the generator would write
    #   now triggers `remove <path>? [y/n/a/q]` (use `--force` to skip);
    # * `--pretend` prints planned removals and changes nothing;
    # * empty component directories (e.g. `src/views/posts`) are pruned,
    #   but shared roots (`src/models`, `spec`, `db/migrate`, ...) and
    #   directories containing unrelated files are never removed;
    # * removing a migration rebuilds `db/migrations.cr`.
    module Destroy
      ROOT_DIRS = [
        "src", "src/models", "src/controllers", "src/channels", "src/jobs",
        "src/mailers", "src/views",
        "spec", "spec/models", "spec/requests", "spec/channels", "spec/jobs",
        "spec/mailers",
        "db", "db/migrate", "lib", "config",
      ]

      @@remove_all : Bool = false
      @@removed = 0
      @@skipped = 0
      @@removed_dirs = Set(String).new
      @@migration_changed = false
      @@notes = [] of String

      def self.run(args : Array(String)) : Int32
        reset!
        rest = [] of String
        args.each do |a|
          case a
          when "--pretend" then Generate.pretend = true
          when "--force"   then Generate.force = true
          else                  rest << a
          end
        end
        kind = rest.shift? || raise Error.new("Usage: saci destroy KIND NAME\nKinds: #{Generate::GENERATOR_KINDS.join(", ")}, scaffold_controller")
        raw = rest.shift? unless kind == "authentication" || kind == "application_record"
        case kind.downcase
        when "model"
          destroy_model(name!(raw, kind))
        when "controller"
          destroy_controller(name!(raw, kind))
        when "migration"
          destroy_migration(name!(raw, kind))
        when "scaffold"
          destroy_scaffold(name!(raw, kind))
        when "channel"
          destroy_channel(name!(raw, kind))
        when "job"
          destroy_job(name!(raw, kind))
        when "mailer"
          destroy_mailer(name!(raw, kind))
        when "resource"
          destroy_resource(name!(raw, kind))
        when "scaffold_controller", "scaffold-controller"
          destroy_scaffold_controller(name!(raw, kind))
        when "authentication", "auth"
          destroy_authentication(raw)
        when "helper"
          destroy_helper(name!(raw, kind))
        when "task"
          destroy_task(name!(raw, kind))
        when "test"
          destroy_model_test(name!(raw, kind))
        when "integration_test", "system_test"
          destroy_integration_test(name!(raw, kind))
        when "benchmark"
          destroy_benchmark(name!(raw, kind))
        when "application_record"
          destroy_application_record
        else
          raise Error.new("Unknown destroy kind '#{kind}'. Kinds: #{Generate::GENERATOR_KINDS.join(", ")}.")
        end

        @@notes.each { |note| Generate.log note }
        prune_empty_dirs!
        if @@migration_changed
          if Generate.pretend?
            Generate.log "  skip db/migrations.cr (pretend: manifest rebuild skipped)"
          else
            Generate.regenerate_manifest!
          end
        end
        Generate.log ""
        Generate.log "Removed #{@@removed} file#{@@removed == 1 ? "" : "s"}#{@@skipped > 0 ? ", skipped #{@@skipped}" : ""}."
        0
      ensure
        Generate.reset_flags!
        reset!
      end

      private def self.name!(raw : String?, kind : String) : String
        raw || raise Error.new("Usage: saci destroy #{kind} NAME")
      end

      private def self.reset! : Nil
        @@remove_all = false
        @@removed = 0
        @@skipped = 0
        @@removed_dirs.clear
        @@migration_changed = false
        @@notes.clear
      end

      def self.destroy_model(raw : String) : Nil
        class_name = Util.class_name(Util.file_name(raw))
        file = Util.file_name(class_name)
        fields = Generate.fields_for_model(class_name)
        remove("src/models/#{file}.cr", Generate.model_source(class_name, fields))
        remove("spec/models/#{file}_spec.cr", Generate.model_spec_source(class_name, fields))
        destroy_migrations("Create#{Record::Inflector.pluralize(class_name)}", "create_#{Record::Inflector.pluralize(Util.file_name(class_name))}")
      end

      def self.destroy_controller(raw : String) : Nil
        base = Util.class_name(Util.file_name(raw.sub(/Controller$/i, "")))
        class_name = "#{base}Controller"
        file = Util.file_name(class_name)
        actions = actions_from("src/controllers/#{file}.cr") || ["index"]
        remove("src/controllers/#{file}.cr", Generate.controller_source(class_name, actions))
        remove("spec/requests/#{file}_spec.cr", Generate.controller_spec_source(base, class_name, actions))
      end

      def self.destroy_migration(raw : String) : Nil
        class_name = Util.class_name(Util.file_name(raw))
        file = Util.file_name(class_name)
        paths = Dir.glob("db/migrate/*_#{file}.cr")
        if paths.empty?
          Generate.log "  skip db/migrate/*_#{file}.cr (not found)"
        else
          paths.each { |path| remove(path, nil) }
        end
      end

      # Removes migrations by their generated class/file suffix. Used by
      # model/scaffold/resource destroy; matches only our naming pattern.
      def self.destroy_migrations(class_name : String, suffix : String) : Nil
        paths = Dir.glob("db/migrate/*_#{suffix}.cr")
        if paths.empty?
          Generate.log "  skip db/migrate/*_#{suffix}.cr (not found)"
        else
          paths.each { |path| remove(path, nil) }
        end
      end

      def self.destroy_scaffold(raw : String) : Nil
        class_name = Util.class_name(Util.file_name(raw))
        file = Util.file_name(class_name)
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Util.file_name(class_name))
        fields = Generate.fields_for_model(class_name)
        remove("src/models/#{file}.cr", Generate.model_source(class_name, fields))
        remove("spec/models/#{file}_spec.cr", Generate.model_spec_source(class_name, fields))
        actions = actions_from("src/controllers/#{Util.file_name(plural)}_controller.cr") || ["index", "show", "create", "update", "destroy"]
        remove("src/controllers/#{Util.file_name(plural)}_controller.cr", Generate.controller_source("#{plural}Controller", actions))
        remove("spec/requests/#{Util.file_name(plural)}_controller_spec.cr",
          Generate.controller_spec_source(plural, "#{plural}Controller", actions))
        destroy_migrations("Create#{plural}", "create_#{table}")
      end

      def self.destroy_channel(raw : String) : Nil
        class_name = "#{Util.class_name(Util.file_name(raw.sub(/Channel$/i, "")))}Channel"
        file = Util.file_name(class_name)
        remove("src/channels/#{file}.cr", Generate.channel_source(class_name))
        remove("spec/channels/#{file}_spec.cr", Generate.channel_spec_source(class_name))
      end

      def self.destroy_job(raw : String) : Nil
        class_name = "#{Util.class_name(Util.file_name(raw.sub(/Job$/i, "")))}Job"
        file = Util.file_name(class_name)
        remove("src/jobs/#{file}.cr", Generate.job_source(class_name))
        remove("spec/jobs/#{file}_spec.cr", Generate.job_spec_source(class_name))
      end

      def self.destroy_mailer(raw : String) : Nil
        class_name = "#{Util.class_name(Util.file_name(raw.sub(/Mailer$/i, "")))}Mailer"
        file = Util.file_name(class_name)
        remove("src/mailers/#{file}.cr", Generate.mailer_source(class_name))
        remove("spec/mailers/#{file}_spec.cr", Generate.mailer_spec_source(class_name))
      end

      def self.destroy_resource(raw : String) : Nil
        class_name = Generate.model_class_name(raw)
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Util.file_name(class_name))
        file = Util.file_name(class_name)
        fields = Generate.fields_for_model(class_name)
        remove("src/models/#{file}.cr", Generate.model_source(class_name, fields))
        remove("spec/models/#{file}_spec.cr", Generate.model_spec_source(class_name, fields))
        remove("src/controllers/#{Util.file_name(plural)}_controller.cr",
          Generate.resource_controller_source(class_name, plural, table, fields))
        remove("spec/requests/#{Util.file_name(plural)}_controller_spec.cr",
          Generate.resource_spec_source(class_name, plural, table, fields))
        remove("src/routes/#{Util.file_name(plural)}_routes.cr", Generate.resource_route_source(plural, table))
        destroy_migrations("Create#{plural}", "create_#{table}")
      end

      def self.destroy_scaffold_controller(raw : String) : Nil
        class_name = Generate.model_class_name(raw)
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Util.file_name(class_name))
        var = Util.file_name(class_name)
        fields = Generate.fields_for_model(class_name)
        remove("src/controllers/#{Util.file_name(plural)}_controller.cr",
          Generate.scaffold_controller_source(class_name, plural, table, var, fields))
        remove("spec/requests/#{Util.file_name(plural)}_controller_spec.cr",
          Generate.scaffold_controller_spec_source(class_name, plural, table, fields))
        {
          "index" => Generate.scaffold_index_view(class_name, plural, table, fields),
          "show"  => Generate.scaffold_show_view(class_name, plural, table, var, fields),
          "new"   => Generate.scaffold_new_view(class_name, plural, table, var, fields),
          "edit"  => Generate.scaffold_edit_view(class_name, plural, table, var, fields),
        }.each do |view, expected|
          remove("src/views/#{table}/#{view}.ecr", expected)
        end
      end

      def self.destroy_authentication(raw : String?) : Nil
        user_class = raw ? Util.class_name(Util.file_name(raw)) : "User"
        table = Record::Inflector.pluralize(Util.file_name(user_class))
        remove("src/models/#{Util.file_name(user_class)}.cr", Generate.auth_user_source(user_class))
        destroy_migrations("Create#{Util.class_name(table)}", "create_#{table}")
        remove("src/controllers/authentication.cr", Generate.auth_module_source(user_class))
        remove("src/controllers/sessions_controller.cr", Generate.auth_sessions_source(user_class))
        remove("src/controllers/passwords_controller.cr", Generate.auth_passwords_source(user_class))
        remove("src/mailers/password_mailer.cr", Generate.auth_mailer_source)
        remove("src/views/sessions/new.ecr", Generate.auth_login_view)
        remove("src/views/passwords/new.ecr", Generate.auth_forgot_view)
        remove("src/views/passwords/create.ecr", Generate.auth_sent_view)
        remove("src/views/passwords/edit.ecr", Generate.auth_reset_view)
        remove("spec/requests/sessions_controller_spec.cr", Generate.auth_spec_source(user_class))

        app_controller = "src/controllers/application_controller.cr"
        auth_controller = "require \"./authentication\"\n\nclass ApplicationController < Saci::Controller\n  include Authentication\nend\n"
        if File.exists?(app_controller)
          current = File.read(app_controller)
          if current == auth_controller || current.strip == auth_controller.strip
            if Generate.pretend?
              Generate.log "  restore #{app_controller} (remove include Authentication)"
            else
              File.write(app_controller, New.application_controller)
              Generate.log "  restore #{app_controller}"
            end
          elsif !current.includes?("include Authentication")
            @@notes << "note: #{app_controller} did not include Authentication; left untouched."
          else
            @@notes << "note: #{app_controller} is customized; remove `include Authentication` manually."
          end
        end
      end

      def self.destroy_helper(raw : String) : Nil
        module_name = "#{Util.class_name(Util.file_name(raw.sub(/Helper$/i, "")))}Helper"
        file = Util.file_name(module_name)
        base = Util.file_name(module_name.sub(/Helper$/, ""))
        remove("src/helpers/#{file}.cr", Generate.helper_source(module_name, base))
        remove("spec/helpers/#{file}_spec.cr", Generate.helper_spec_source(module_name, base))
      end

      def self.destroy_task(raw : String) : Nil
        segments = raw.split(":").map(&.strip)
        path = (["lib", "tasks"] + segments).join("/") + ".cr"
        remove(path, Generate.task_source(raw))
      end

      def self.destroy_model_test(raw : String) : Nil
        file = Util.file_name(Util.class_name(Util.file_name(raw)))
        remove("spec/models/#{file}_test.cr", nil)
      end

      def self.destroy_integration_test(raw : String) : Nil
        base = Util.file_name(raw)
        remove("spec/integration/#{base}_test.cr", nil)
      end

      def self.destroy_benchmark(raw : String) : Nil
        base = Util.file_name(raw.gsub("#", "_").gsub("::", "_"))
        remove("benchmarks/#{base}_benchmark.cr", nil)
      end

      def self.destroy_application_record : Nil
        remove("src/models/application_record.cr", New.application_record)
      end

      # Deletes one owned file. `expected` is the content the generator
      # would produce now; a mismatch prompts unless `--force`/all was
      # answered. `expected == nil` means the path itself is unambiguous
      # (timestamped migration, test skeleton), so no content prompt.
      def self.remove(path : String, expected : String?) : Nil
        unless File.exists?(path)
          Generate.log "  skip #{path} (not found)"
          return
        end
        if Generate.pretend?
          Generate.log "  remove #{path}"
          @@migration_changed = true if path.starts_with?("db/migrate/") && path.ends_with?(".cr")
          return
        end

        if expected.nil? || Generate.force? || File.read(path) == expected
          delete_file(path)
          return
        end

        answer = @@remove_all ? :all : Generate.confirm("    remove #{path}? [y/n/a/q] ")
        case answer
        when :yes, :all
          @@remove_all = true if answer == :all
          delete_file(path)
        when :quit
          raise Error.new("Destroy aborted by user.")
        else
          @@skipped += 1
          Generate.log "  skip #{path} (modified; use --force to remove)"
          Generate.error.puts "warning: skipping modified file #{path} (rerun with --force to remove it)"
        end
      end

      private def self.delete_file(path : String) : Nil
        File.delete(path)
        @@removed += 1
        @@removed_dirs << File.dirname(path)
        @@migration_changed = true if path.starts_with?("db/migrate/") && path.ends_with?(".cr")
        Generate.log "  remove #{path}"
      end

      # Best-effort action discovery for destroy controller/scaffold: keeps
      # the expected-content comparison useful even when the user does not
      # repeat the action list.
      def self.actions_from(path : String) : Array(String)?
        return nil unless File.exists?(path)
        actions = [] of String
        File.read(path).scan(/(?m)^\s*def\s+([a-z][a-z0-9_]*[?!]?)/) do |m|
          name = m[1]
          next if name == "initialize"
          actions << name
        end
        actions.empty? ? nil : actions
      end

      private def self.prune_empty_dirs! : Nil
        return if Generate.pretend?
        dirs = @@removed_dirs.to_a
        changed = true
        while changed
          changed = false
          dirs.sort_by { |dir| -dir.count("/") }.each do |dir|
            next if ROOT_DIRS.includes?(dir)
            next unless Dir.exists?(dir)
            next unless Dir.empty?(dir)
            Dir.delete(dir)
            Generate.log "  rmdir #{dir}"
            changed = true
          end
        end
      end
    end
  end
end
