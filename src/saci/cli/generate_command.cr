module Saci
  module CLI
    # `saci generate model|controller|migration ...` (alias `saci g ...`).
    module Generate
      FIELD_RE = /\A([a-z][a-z0-9_]*):([a-z]+)\z/

      # Crystal type per migration field type.
      CRYSTAL_TYPES = {
        "string"   => "String",
        "text"     => "String",
        "integer"  => "Int64",
        "bigint"   => "Int64",
        "float"    => "Float64",
        "boolean"  => "Bool",
        "datetime" => "Time",
      }

      def self.run(args : Array(String)) : Int32
        kind = args.shift? || raise Error.new("Usage: saci generate KIND NAME [fields...]\nKinds: model, controller, migration, channel, job, mailer, scaffold")
        case kind.downcase
        when "model"      then model(args)
        when "controller" then controller(args)
        when "migration"  then migration(args)
        when "channel"    then channel(args)
        when "job"        then job(args)
        when "mailer"     then mailer(args)
        when "scaffold"   then scaffold(args)
        else                   raise Error.new("Unknown generator '#{kind}'. Kinds: model, controller, migration, channel, job, mailer, scaffold.")
        end
        0
      end

      # -- fields ------------------------------------------------------------

      alias Field = Tuple(String, String)

      def self.parse_fields(raw : Array(String)) : Array(Field)
        raw.map do |f|
          m = FIELD_RE.match(f) || raise Error.new("Bad field '#{f}'. Expected name:type (types: #{CRYSTAL_TYPES.keys.join(", ")}).")
          type = m[2]
          raise Error.new("Unknown type '#{type}' in field '#{f}'. Valid: #{CRYSTAL_TYPES.keys.join(", ")}.") unless CRYSTAL_TYPES.has_key?(type)
          {m[1], type}
        end
      end

      # -- model ---------------------------------------------------------------

      def self.model(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate model Name [field:type ...]")
        class_name = Util.class_name(Util.file_name(raw_name))
        fields = parse_fields(args)
        ensure_app_layout!

        File.write("src/models/#{Util.file_name(class_name)}.cr", model_source(class_name, fields))
        puts "  create src/models/#{Util.file_name(class_name)}.cr"

        spec_path = "spec/models/#{Util.file_name(class_name)}_spec.cr"
        Dir.mkdir_p("spec/models")
        File.write(spec_path, model_spec_source(class_name, fields))
        puts "  create #{spec_path}"

        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))
        migration_name = "Create#{Record::Inflector.pluralize(class_name)}"
        create_migration_file(migration_name, create_table_source(migration_name, table, fields))
        puts "Add routes to your router, e.g.:"
        puts "  r.resources \"#{table}\", #{Record::Inflector.pluralize(class_name)}Controller"
      end

      def self.model_source(class_name : String, fields : Array(Field)) : String
        cols = fields.map { |(name, type)| "  column #{name} : #{CRYSTAL_TYPES[type]}" }.join("\n")
        <<-CRYSTAL
        class #{class_name} < ApplicationRecord
          column id : Int64, primary: true
        #{cols}
          timestamps
        end
        CRYSTAL
      end

      def self.model_spec_source(class_name : String, fields : Array(Field)) : String
        <<-CRYSTAL
        require "../spec_helper"

        describe #{class_name} do
          before_each do
            Saci::Record.clean_database!
          end

          it "creates and finds records" do
            record = #{class_name}.create!(#{sample_args(fields)})
            record.persisted?.should be_true
            #{class_name}.find(record.id.not_nil!).id.should eq(record.id)
          end

          it "rejects unknown attributes" do
            expect_raises(Saci::Record::UnknownAttributeError) do
              #{class_name}.new(bogus_attribute_xyz: 1)
            end
          end
        end
        CRYSTAL
      end

      # Sensible sample values per field type for generated specs.
      private def self.sample_args(fields : Array(Field)) : String
        fields.first(2).map do |(name, type)|
          value = case type
                  when "string", "text"    then "\"example #{name}\""
                  when "integer", "bigint" then "1"
                  when "float"             then "1.5"
                  when "boolean"           then "true"
                  when "datetime"          then "Time.utc"
                  else                          "nil"
                  end
          "#{name}: #{value}"
        end.join(", ")
      end

      # -- controller ------------------------------------------------------------

      def self.controller(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate controller Name [action ...]")
        base = Util.class_name(Util.file_name(raw_name.sub(/Controller$/i, "")))
        class_name = "#{base}Controller"
        actions = args.empty? ? ["index"] : args
        actions.each do |a|
          raise Error.new("Bad action name '#{a}'. Use lowercase/underscores.") unless /\A[a-z][a-z0-9_]*[?!]?\z/.matches?(a)
        end
        ensure_app_layout!

        path = "src/controllers/#{Util.file_name(class_name)}.cr"
        File.write(path, controller_source(class_name, actions))
        puts "  create #{path}"

        spec_path = "spec/requests/#{Util.file_name(class_name)}_spec.cr"
        Dir.mkdir_p("spec/requests")
        File.write(spec_path, controller_spec_source(base, class_name, actions))
        puts "  create #{spec_path}"

        puts "Add routes to your router, e.g.:"
        actions.each do |a|
          puts "  #{controller_route_for(Util.file_name(base), class_name, a)}"
        end
      end

      # RESTful route line per action (single source of truth for hints
      # and generated request specs): index/show/new/edit are GET,
      # create is POST, update is PATCH, destroy is DELETE.
      def self.controller_route_for(base_path : String, class_name : String, action : String) : String
        case action
        when "index"   then "r.get \"/#{base_path}\", #{class_name}, :index"
        when "show"    then "r.get \"/#{base_path}/:id\", #{class_name}, :show"
        when "new"     then "r.get \"/#{base_path}/new\", #{class_name}, :new"
        when "edit"    then "r.get \"/#{base_path}/:id/edit\", #{class_name}, :edit"
        when "create"  then "r.post \"/#{base_path}\", #{class_name}, :create"
        when "update"  then "r.patch \"/#{base_path}/:id\", #{class_name}, :update"
        when "destroy" then "r.delete \"/#{base_path}/:id\", #{class_name}, :destroy"
        else                "r.get \"/#{base_path}/#{action}\", #{class_name}, :#{action}"
        end
      end

      # Real HTTP verb + path per action for generated request specs
      # (create->POST, update->PATCH, destroy->DELETE; rest GET).
      def self.controller_request_for(base_path : String, action : String) : Tuple(String, String)
        case action
        when "index"   then {"get", "/#{base_path}"}
        when "show"    then {"get", "/#{base_path}/1"}
        when "new"     then {"get", "/#{base_path}/new"}
        when "edit"    then {"get", "/#{base_path}/1/edit"}
        when "create"  then {"post", "/#{base_path}"}
        when "update"  then {"patch", "/#{base_path}/1"}
        when "destroy" then {"delete", "/#{base_path}/1"}
        else                {"get", "/#{base_path}/#{action}"}
        end
      end

      def self.controller_source(class_name : String, actions : Array(String)) : String
        body = actions.map do |a|
          "  def #{a}\n    render text: \"#{class_name}##{a}\"\n  end"
        end.join("\n\n")
        <<-CRYSTAL
        class #{class_name} < ApplicationController
        #{body}
        end
        CRYSTAL
      end

      def self.controller_spec_source(base : String, class_name : String, actions : Array(String)) : String
        base_path = Util.file_name(base)
        routes = actions.map { |a| "      #{controller_route_for(base_path, class_name, a)}" }.join("\n")
        tests = actions.map do |a|
          verb, path = controller_request_for(base_path, a)
          <<-TEST
            it "serves #{a}" do
              Saci::TestSession.serve(router) do |app|
                resp = app.#{verb}("#{path}")
                resp.status_code.should eq(200)
              end
            end
          TEST
        end.join("\n")
        <<-CRYSTAL
        require "../spec_helper"

        describe "#{class_name} requests" do
          router = Saci::Router.new.draw do |r|
        #{routes}
          end

          before_each do
            Saci::Record.clean_database!
          end

        #{tests}
        end
        CRYSTAL
      end

      # -- migration ---------------------------------------------------------------

      def self.migration(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate migration Name [field:type ...] [--unique]")
        class_name = Util.class_name(Util.file_name(raw_name))
        raise Error.new("Bad migration name '#{raw_name}'. Use CamelCase (e.g. AddBioToUsers).") unless /\A[A-Z][A-Za-z0-9]*\z/.matches?(class_name)
        unique, remaining = extract_unique_flag(args)
        ensure_app_layout!

        # `AddIndex...` name pattern (or --unique) emits add_index, not
        # add_column: `saci g migration AddIndexToFollows follower_id --unique`
        if m = /\AAddIndexTo(.+)\z/.match(class_name)
          table = Record::Inflector.underscore(m[1])
          cols = parse_index_columns(remaining)
          raise Error.new("AddIndex migration '#{class_name}' needs at least one column (e.g. saci g migration #{class_name} follower_id).") if cols.empty?
          create_migration_file(class_name, add_index_source(class_name, table, cols, unique))
        elsif m = /\AAddIndex(.+)To(.+)\z/.match(class_name)
          table = Record::Inflector.underscore(m[2])
          cols = parse_index_columns(remaining)
          cols = [Record::Inflector.underscore(m[1])] if cols.empty?
          create_migration_file(class_name, add_index_source(class_name, table, cols, unique))
        elsif unique
          if m2 = /\AAdd(.+)To(.+)\z/.match(class_name)
            table = Record::Inflector.underscore(m2[2])
            cols = parse_index_columns(remaining)
            raise Error.new("Index migration '#{class_name}' with --unique needs at least one column.") if cols.empty?
            create_migration_file(class_name, add_index_source(class_name, table, cols, unique))
          else
            raise Error.new("--unique needs an Add...To... migration name (e.g. AddIndexToFollows follower_id --unique).")
          end
        elsif m = /\AAdd(.+)To(.+)\z/.match(class_name)
          # m[2] is already plural ("Users") — underscore only, no re-pluralize.
          table = Record::Inflector.underscore(m[2])
          fields = parse_fields(remaining)
          create_migration_file(class_name, add_columns_source(class_name, table, fields))
        else
          # Non-Add names still validate field syntax when given.
          parse_fields(remaining) unless remaining.empty?
          create_migration_file(class_name, empty_migration_source(class_name))
          puts "note: empty change — fill in up/down or reversible operations."
        end
      end

      # Splits `--unique` / `--unique=true|false` out of migration fields.
      def self.extract_unique_flag(args : Array(String)) : Tuple(Bool, Array(String))
        unique = false
        remaining = [] of String
        args.each do |a|
          if a == "--unique"
            unique = true
          elsif a.starts_with?("--unique=")
            v = a.split("=", 2)[1].downcase
            unique = (v == "true" || v == "1")
          else
            remaining << a
          end
        end
        {unique, remaining}
      end

      # Index columns accept bare names (`follower_id`) or `name:type`
      # (type is validated but ignored — indexes need only the column).
      def self.parse_index_columns(raw : Array(String)) : Array(String)
        raw.map do |f|
          if m = FIELD_RE.match(f)
            type = m[2]
            raise Error.new("Unknown type '#{type}' in field '#{f}'. Valid: #{CRYSTAL_TYPES.keys.join(", ")}.") unless CRYSTAL_TYPES.has_key?(type)
            m[1]
          elsif /\A[a-z][a-z0-9_]*\z/.matches?(f)
            f
          else
            raise Error.new("Bad column '#{f}'. Expected name or name:type (types: #{CRYSTAL_TYPES.keys.join(", ")}).")
          end
        end
      end

      def self.add_index_source(class_name : String, table : String, columns : Array(String), unique : Bool) : String
        cols_src = columns.size == 1 ? ":#{columns.first}" : "[#{columns.map { |c| ":#{c}" }.join(", ")}]"
        opts = unique ? ", unique: true" : ""
        <<-CRYSTAL
        class #{class_name} < Saci::Record::Migration
          def change
            add_index :#{table}, #{cols_src}#{opts}
          end
        end
        CRYSTAL
      end

      def self.create_table_source(class_name : String, table : String, fields : Array(Field)) : String
        cols = (fields.map { |(name, type)| "      t.#{type} :#{name}" } + ["      t.timestamps"]).join("\n")
        <<-CRYSTAL
        class #{class_name} < Saci::Record::Migration
          def change
            create_table :#{table} do |t|
        #{cols}
            end
          end
        end
        CRYSTAL
      end

      def self.add_columns_source(class_name : String, table : String, fields : Array(Field)) : String
        ops = fields.map { |(name, type)| "      add_column :#{table}, :#{name}, :#{type}" }.join("\n")
        <<-CRYSTAL
        class #{class_name} < Saci::Record::Migration
          def change
        #{ops}
          end
        end
        CRYSTAL
      end

      def self.empty_migration_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < Saci::Record::Migration
          def change
            # TODO: create_table / add_column / add_index, or define up/down.
          end
        end
        CRYSTAL
      end

      def self.create_migration_file(class_name : String, source : String) : String
        version = Util.timestamp_version
        # Bump within the same second to keep filenames unique.
        while Dir.glob("db/migrate/#{version}_*.cr").any?
          version = (version.to_i64 + 1).to_s
        end
        file = "#{Util.file_name(class_name)}"
        path = "db/migrate/#{version}_#{file}.cr"
        File.write(path, source)
        puts "  create #{path}"
        regenerate_manifest!
        path
      end

      # Rebuilds db/migrations.cr from the files on disk (sorted = order).
      # Fails fast when a file's migration class doesn't match its filename
      # (otherwise the manifest references an undefined constant) or when
      # two files declare the same class.
      def self.regenerate_manifest! : Nil
        files = Dir.glob("db/migrate/*.cr").sort
        names = files.map do |f|
          expected = Util.class_name(File.basename(f, ".cr").sub(/\A\d+_/, ""))
          declared = File.read(f).scan(/^\s*class\s+([A-Z][A-Za-z0-9_]*)/).map(&.[1]).first?
          if declared && declared != expected
            raise Error.new("Migration #{f} declares class #{declared} but the filename implies #{expected}. Rename the file or the class so they match.")
          end
          expected
        end
        dupes = names.tally.select { |_, count| count > 1 }.keys
        unless dupes.empty?
          raise Error.new("Duplicate migration class(es) #{dupes.join(", ")} in db/migrate/. Keep one file per class.")
        end
        File.write("db/migrations.cr", manifest_source(files, names))
        puts "  update db/migrations.cr (#{names.size} migration#{names.size == 1 ? "" : "s"})"
      end

      def self.manifest_source(files : Array(String), names : Array(String)) : String
        requires = files.map { |f| "require \"./migrate/#{File.basename(f, ".cr")}\"" }.join("\n")
        list = names.join(", ")
        <<-CRYSTAL
        # Auto-generated by `saci generate migration` — do not edit by hand.
        #{requires}
        SACI_MIGRATIONS = [#{list}] of Saci::Record::Migration.class
        CRYSTAL
      end

      # -- channel -----------------------------------------------------------------

      def self.channel(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate channel Name")
        base = Util.class_name(Util.file_name(raw_name.sub(/Channel$/i, "")))
        class_name = "#{base}Channel"
        ensure_app_layout!

        Dir.mkdir_p("src/channels")
        path = "src/channels/#{Util.file_name(class_name)}.cr"
        File.write(path, channel_source(class_name))
        puts "  create #{path}"

        Dir.mkdir_p("spec/channels")
        spec_path = "spec/channels/#{Util.file_name(class_name)}_spec.cr"
        File.write(spec_path, channel_spec_source(class_name))
        puts "  create #{spec_path}"

        puts "Mount it in your router, e.g.:"
        puts "  r.cable \"/cable\", #{class_name}"
      end

      def self.channel_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < Saci::Cable::Channel
          def subscribed
            stream_from "lobby"
          end

          def receive(data)
            transmit({echo: data})
          end
        end
        CRYSTAL
      end

      def self.channel_spec_source(class_name : String) : String
        <<-CRYSTAL
        require "../spec_helper"

        describe #{class_name} do
          it "echoes messages back to subscribers" do
            router = Saci::Router.new.draw do |r|
              r.cable "/cable", #{class_name}
            end
            Saci::TestSession.serve(router) do |app|
              client = Saci::Cable::TestClient.new(app.host, app.port)
              ident = client.subscribe("#{class_name}")
              client.send_message(ident, {text: "hi"})
              msg = client.next_message
              msg["message"].as_h["echo"].as_h["text"].as_s.should eq("hi")
              client.close
            end
          end
        end
        CRYSTAL
      end

      # -- job + mailer --------------------------------------------------------------

      def self.job(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate job Name")
        base = Util.class_name(Util.file_name(raw_name.sub(/Job$/i, "")))
        class_name = "#{base}Job"
        ensure_app_layout!

        Dir.mkdir_p("src/jobs")
        path = "src/jobs/#{Util.file_name(class_name)}.cr"
        File.write(path, job_source(class_name))
        puts "  create #{path}"

        Dir.mkdir_p("spec/jobs")
        spec_path = "spec/jobs/#{Util.file_name(class_name)}_spec.cr"
        File.write(spec_path, job_spec_source(class_name))
        puts "  create #{spec_path}"
      end

      def self.job_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < Saci::Job::Base
          queue_as :default

          def perform(payload : JSON::Any) : Nil
          end
        end
        CRYSTAL
      end

      def self.job_spec_source(class_name : String) : String
        <<-CRYSTAL
        require "../spec_helper"

        describe #{class_name} do
          it "performs inline" do
            Saci::Job.with_adapter(:inline) do
              #{class_name}.perform_later({ran: true})
            end
          end
        end
        CRYSTAL
      end

      def self.mailer(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate mailer Name")
        base = Util.class_name(Util.file_name(raw_name.sub(/Mailer$/i, "")))
        class_name = "#{base}Mailer"
        ensure_app_layout!

        Dir.mkdir_p("src/mailers")
        path = "src/mailers/#{Util.file_name(class_name)}.cr"
        File.write(path, mailer_source(class_name))
        puts "  create #{path}"

        Dir.mkdir_p("spec/mailers")
        spec_path = "spec/mailers/#{Util.file_name(class_name)}_spec.cr"
        File.write(spec_path, mailer_spec_source(class_name))
        puts "  create #{spec_path}"
      end

      def self.mailer_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < Saci::Mailer::Base
          default_from "noreply@example.com"

          def self.welcome(email : String) : Saci::Mailer::Mail
            mail(to: email, subject: "Welcome!") do |format|
              format.text { "Welcome, \#{email}!" }
              format.html { "<h1>Welcome, \#{email}!</h1>" }
            end
          end
        end
        CRYSTAL
      end

      def self.mailer_spec_source(class_name : String) : String
        <<-CRYSTAL
        require "../spec_helper"

        describe #{class_name} do
          it "delivers a welcome email" do
            Saci::Mailer.clear_deliveries!
            #{class_name}.welcome("a@b.c").deliver_now
            Saci::Mailer.deliveries.size.should eq(1)
            Saci::Mailer.deliveries.first.to.should eq(["a@b.c"])
          end
        end
        CRYSTAL
      end

      # -- scaffold ------------------------------------------------------------------
      # One command for the standard REST stack: model + migration +
      # controller (all REST actions) + specs. Prints the route to add
      # (routes stay hand-edited by design).
      def self.scaffold(args : Array(String)) : Nil
        raw_name = args.first? || raise Error.new("Usage: saci generate scaffold Name [field:type ...]")
        fields = args.size > 1 ? args[1..] : [] of String
        class_name = Util.class_name(Util.file_name(raw_name))
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))

        model([class_name] + fields)
        controller([plural, "index", "show", "create", "update", "destroy"])

        puts ""
        puts "Add to your router:"
        puts "  r.resources \"#{table}\", #{plural}Controller"
      end

      private def self.ensure_app_layout! : Nil
        unless Dir.exists?("src/models") && Dir.exists?("src/controllers") && Dir.exists?("db/migrate")
          raise Error.new("Not a Saci app directory (missing src/models, src/controllers or db/migrate). Run `saci new` first or `cd` into your app.")
        end
      end
    end
  end
end
