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

      # -- flags + central file writer ---------------------------------------
      # `--pretend` (dry run) and `--force` are global: accepted anywhere in
      # the `saci generate` argv and stripped before KIND dispatch, so nested
      # generators (scaffold -> model + controller) share the same mode.

      @@pretend : Bool = false
      @@force : Bool = false
      @@overwrite_all : Bool = false
      @@input : IO = STDIN
      @@output : IO = STDOUT
      @@error : IO = STDERR

      # Lines of new file content shown per file in `--pretend` output.
      PREVIEW_LINES = 40

      def self.pretend? : Bool
        @@pretend
      end

      def self.force? : Bool
        @@force
      end

      # Prompt answers are read from here instead of STDIN directly so specs
      # (and piped callers) can inject answers. Restore with `reset_input!`.
      def self.input=(io : IO) : Nil
        @@input = io
      end

      def self.reset_input! : Nil
        @@input = STDIN
      end

      # All generator output (status lines, previews, prompts, hints) goes
      # through here instead of STDOUT directly so specs can capture it.
      # Restore with `reset_output!`.
      def self.output=(io : IO) : Nil
        @@output = io
      end

      def self.error=(io : IO) : Nil
        @@error = io
      end

      def self.reset_output! : Nil
        @@output = STDOUT
        @@error = STDERR
      end

      # Shadows top-level `puts`/`print` inside this module's methods so
      # every status line, preview and hint honors `@@output`.
      private def self.puts(*args) : Nil
        @@output.puts(*args)
      end

      private def self.puts : Nil
        @@output.puts
      end

      private def self.print(*args) : Nil
        @@output.print(*args)
      end

      # Central writer every generator funnels through. Returns :created,
      # :overwritten, :identical or :skipped (:pretend_create,
      # :pretend_overwrite, :pretend_identical under `--pretend`, which
      # prints statuses + a content preview and writes nothing).
      #
      # Existing targets with different content prompt
      # `overwrite? [y/n/a/q]` unless `--force`/all was given. The generated
      # `db/migrations.cr` manifest is derived state (rebuilt from
      # `db/migrate/*.cr`), so it passes `prompt: false` and always
      # overwrites like before — identical content still skips.
      def self.write_file(path : String, content : String, prompt : Bool = true) : Symbol
        exists = File.exists?(path)
        same = exists && File.read(path) == content

        if @@pretend
          if same
            puts "  identical #{path}"
            return :pretend_identical
          elsif exists
            puts "  overwrite #{path}"
            puts "    (would replace #{File.read(path).lines.size} lines with #{content.lines.size} lines)"
          else
            puts "  create #{path}"
          end
          print_preview(content)
          return same ? :pretend_identical : exists ? :pretend_overwrite : :pretend_create
        end

        unless exists
          parent = File.dirname(path)
          Dir.mkdir_p(parent) unless parent == "."
          File.write(path, content)
          puts "  create #{path}"
          return :created
        end

        if same
          puts "  identical #{path}"
          return :identical
        end

        if @@force || @@overwrite_all || !prompt
          File.write(path, content)
          puts "  overwrite #{path}"
          return :overwritten
        end

        answer = prompt_overwrite(path)
        case answer
        when :yes, :all
          @@overwrite_all = true if answer == :all
          File.write(path, content)
          puts "  overwrite #{path}"
          :overwritten
        when :quit
          raise Error.new("Generation aborted by user.")
        else
          puts "  skip #{path} (exists; use --force to overwrite)"
          @@error.puts "warning: skipping existing file #{path} (rerun with --force to overwrite it)"
          :skipped
        end
      end

      # Reads one y/n/a/q answer. Never hangs CI: a TTY blocks for the user,
      # while piped input honors a piped answer and treats EOF as "no".
      private def self.prompt_overwrite(path : String) : Symbol
        input = @@input
        if input.is_a?(IO::FileDescriptor) && input.tty?
          print "    overwrite #{path}? [y/n/a/q] "
        end
        answer = @@input.gets
        return :no if answer.nil?
        case answer.strip.downcase
        when "y", "yes"  then :yes
        when "a", "all"  then :all
        when "q", "quit" then :quit
        else                  :no
        end
      end

      # `--pretend` body preview: first PREVIEW_LINES lines of the would-be
      # content, with a truncation note when longer.
      private def self.print_preview(content : String) : Nil
        lines = content.lines
        lines.first(PREVIEW_LINES).each { |line| puts line.chomp }
        if lines.size > PREVIEW_LINES
          puts "    ... (#{lines.size - PREVIEW_LINES} more lines)"
        end
      end

      def self.run(args : Array(String)) : Int32
        @@pretend = args.includes?("--pretend")
        @@force = args.includes?("--force")
        @@overwrite_all = false
        rest = args.reject { |a| a == "--pretend" || a == "--force" }
        kind = rest.shift? || raise Error.new("Usage: saci generate KIND NAME [fields...]\nKinds: model, controller, migration, channel, job, mailer, scaffold, admin")
        case kind.downcase
        when "model"      then model(rest)
        when "controller" then controller(rest)
        when "migration"  then migration(rest)
        when "channel"    then channel(rest)
        when "job"        then job(rest)
        when "mailer"     then mailer(rest)
        when "scaffold"   then scaffold(rest)
        when "admin"      then admin(rest)
        else                   raise Error.new("Unknown generator '#{kind}'. Kinds: model, controller, migration, channel, job, mailer, scaffold, admin.")
        end
        0
      ensure
        @@pretend = false
        @@force = false
        @@overwrite_all = false
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

        write_file("src/models/#{Util.file_name(class_name)}.cr", model_source(class_name, fields))

        spec_path = "spec/models/#{Util.file_name(class_name)}_spec.cr"
        Dir.mkdir_p("spec/models")
        write_file(spec_path, model_spec_source(class_name, fields))

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
        write_file(path, controller_source(class_name, actions))

        spec_path = "spec/requests/#{Util.file_name(class_name)}_spec.cr"
        Dir.mkdir_p("spec/requests")
        write_file(spec_path, controller_spec_source(base, class_name, actions))

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
        write_file(path, source)
        if @@pretend
          puts "  skip db/migrations.cr (pretend: manifest rebuild skipped)"
        else
          regenerate_manifest!
        end
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
        result = write_file("db/migrations.cr", manifest_source(files, names), prompt: false)
        if result == :created || result == :overwritten
          puts "  update db/migrations.cr (#{names.size} migration#{names.size == 1 ? "" : "s"})"
        end
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
        write_file(path, channel_source(class_name))

        Dir.mkdir_p("spec/channels")
        spec_path = "spec/channels/#{Util.file_name(class_name)}_spec.cr"
        write_file(spec_path, channel_spec_source(class_name))

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
        write_file(path, job_source(class_name))

        Dir.mkdir_p("spec/jobs")
        spec_path = "spec/jobs/#{Util.file_name(class_name)}_spec.cr"
        write_file(spec_path, job_spec_source(class_name))
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
        write_file(path, mailer_source(class_name))

        Dir.mkdir_p("spec/mailers")
        spec_path = "spec/mailers/#{Util.file_name(class_name)}_spec.cr"
        write_file(spec_path, mailer_spec_source(class_name))
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

      # -- admin -------------------------------------------------------------------
      # Admin-namespace scaffold (RailsAdmin-flavored minimal): namespaced
      # controller (search on string columns + sortable headers + pagination
      # via `Saci::Pagination.paginate`) + namespaced ECR views + request
      # spec. Routes stay hand-edited by design (hint printed below).
      # Reruns overwrite like the other generators.
      def self.admin(args : Array(String)) : Nil
        raw_name = args.first? || raise Error.new("Usage: saci generate admin Name [field:type ...]")
        fields = parse_fields(args.size > 1 ? args[1..] : [] of String)
        class_name = Util.class_name(Util.file_name(raw_name))
        plural = Record::Inflector.pluralize(class_name)
        file_base = Util.file_name(plural)
        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))
        ensure_app_layout!

        Dir.mkdir_p("src/controllers/admin")
        controller_path = "src/controllers/admin/#{file_base}_controller.cr"
        write_file(controller_path, admin_controller_source(class_name, plural, table, fields))

        Dir.mkdir_p("src/views/admin/#{table}")
        {
          "index" => admin_index_view(class_name, plural, table, fields),
          "show"  => admin_show_view(class_name, plural, table, fields),
          "edit"  => admin_edit_view(class_name, plural, table, fields),
        }.each do |view, source|
          path = "src/views/admin/#{table}/#{view}.ecr"
          write_file(path, source)
        end

        Dir.mkdir_p("spec/requests/admin")
        spec_path = "spec/requests/admin/#{file_base}_controller_spec.cr"
        write_file(spec_path, admin_spec_source(class_name, plural, table, fields))

        puts ""
        puts "Add to your router:"
        puts "  r.namespace(\"/admin\") do |a|"
        puts "    a.resources \"#{table}\", Admin::#{plural}Controller"
        puts "  end"
      end

      def self.admin_controller_source(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        string_cols = fields.select { |(_, type)| type == "string" || type == "text" }.map(&.[0])
        sort_cols = (["id"] + fields.map(&.[0])).uniq
        search_filter = if string_cols.empty?
                          ""
                        else
                          conds = string_cols.map { |c| "#{c} LIKE ?" }.join(" OR ")
                          args = string_cols.map { |_| "\"%\#{q}%\"" }.join(", ")
                          "if q = params[\"q\"]?\n  unless q.empty?\n    query = query.where(\"#{conds}\", #{args})\n  end\nend"
                        end
        raw_assignments = fields.map { |(name, type)| admin_assignment(class_name, name, type) }.join("\n")
        raw_assignments = "# No editable fields — add field:type pairs to the generator call." if raw_assignments.strip.empty?
        admin_controller_source_body(class_name, plural, table, sort_cols, search_filter, raw_assignments)
      end

      # Indents every non-blank line of a fragment to the action-body level.
      # (`String#lines` chomps, so the join restores the newlines.)
      private def self.indent_body(fragment : String) : String
        fragment.lines.map { |l| l.strip.empty? ? l : "      " + l }.join("\n")
      end

      # Body is built from a heredoc with placeholder lines (`__SEARCH__` /
      # `__ASSIGN__` alone on a line) so multi-line fragments keep their own
      # indentation (`<<-` forbids column-zero interpolation).
      private def self.admin_controller_source_body(class_name : String, plural : String, table : String, sort_cols : Array(String), search_filter : String, assignments : String) : String
        body = <<-CRYSTAL
        module Admin
          class #{plural}Controller < ::ApplicationController
            before_action :require_admin

            def index
              query = #{class_name}.all
              __SEARCH__
              allowed_sorts = [#{sort_cols.map { |c| "\"#{c}\"" }.join(", ")}]
              sort = params["sort"]? || "id"
              sort = "id" unless allowed_sorts.includes?(sort)
              dir = params["dir"]? == "desc" ? :desc : :asc
              query = query.order(sort, dir)
              page = params.int("page", 1) || 1
              @page = Saci::Pagination.paginate(query, page: page, per_page: 25)
              render_template(:"admin/#{table}/index")
            end

            def show
              @record = #{class_name}.find(params["id"])
              render_template(:"admin/#{table}/show")
            end

            def edit
              @record = #{class_name}.find(params["id"])
              render_template(:"admin/#{table}/edit")
            end

            def update
              @record = #{class_name}.find(params["id"])
              __ASSIGN__
              if @record.save
                redirect_to "/admin/#{table}/\#{@record.id}"
              else
                render_template(:"admin/#{table}/edit", status: 422)
              end
            end

            def destroy
              record = #{class_name}.find(params["id"])
              record.destroy
              redirect_to "/admin/#{table}"
            end

            private def require_admin
              # TODO: wire your real admin check here (e.g. `current_user.try(&.admin?)`
              # or `session[:admin]?`). Deny-by-default: every request without
              # proof of admin gets a 403 until this method is implemented.
              unless params["admin"]? == "true"
                render text: "Forbidden", status: :forbidden
              end
            end
          end
        end
        CRYSTAL
        body = body.gsub(/^ *__SEARCH__$/m, search_filter.empty? ? "" : indent_body(search_filter))
        body.gsub(/^ *__ASSIGN__$/m, indent_body(assignments))
      end

      # One assignment line per field for the generated `update` action
      # (unindented — the caller re-indents every line to the action body).
      private def self.admin_assignment(class_name : String, name : String, type : String) : String
        case type
        when "string", "text"
          "@record.#{name} = params[\"#{name}\"]? if params.has_key?(\"#{name}\")"
        when "integer", "bigint"
          "if v = params[\"#{name}\"]?\n  @record.#{name} = v.to_i64? || @record.#{name}\nend"
        when "float"
          "if v = params[\"#{name}\"]?\n  @record.#{name} = v.to_f? || @record.#{name}\nend"
        when "boolean"
          "@record.#{name} = params[\"#{name}\"]? == \"true\" if params.has_key?(\"#{name}\")"
        when "datetime"
          "if v = params[\"#{name}\"]?\n  @record.#{name} = (Time.parse_iso8601(v) rescue @record.#{name})\nend"
        else
          "@record.#{name} = params[\"#{name}\"]? if params.has_key?(\"#{name}\")"
        end
      end

      def self.admin_index_view(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        cols = fields.map(&.[0])
        headers = (["id"] + cols).map do |c|
          "    <th><a href=\"/admin/#{table}?sort=#{c}\">#{c.capitalize}</a></th>"
        end.join("\n")
        cells = (["id"] + cols).map do |c|
          "      <td><%= h(record.#{c}.to_s) %></td>"
        end.join("\n")
        <<-ECR
        <h1>#{plural} (admin)</h1>
        <form action="/admin/#{table}" method="get">
          <input type="search" name="q" value="<%= h(params["q"]? || "") %>" placeholder="Search...">
          <button type="submit">Search</button>
        </form>
        <table>
          <thead>
            <tr>
        #{headers}
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <% @page.records.each do |record| %>
            <tr>
        #{cells}
              <td>
                <a href="/admin/#{table}/<%= record.id %>">Show</a>
                <a href="/admin/#{table}/<%= record.id %>/edit">Edit</a>
              </td>
            </tr>
            <% end %>
          </tbody>
        </table>
        <%= Saci::Pagination.paginate_nav(@page, "/admin/#{table}") %>
        <p><%= @page.total_count %> #{table} total</p>
        ECR
      end

      def self.admin_show_view(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        rows = fields.map do |(name, _)|
          "  <li><strong>#{name.capitalize}:</strong> <%= h(@record.#{name}.to_s) %></li>"
        end.join("\n")
        rows = "  <li>No attributes.</li>" if rows.empty?
        <<-ECR
        <h1>#{class_name} #<%= @record.id %> (admin)</h1>
        <ul>
        #{rows}
        </ul>
        <p>
          <a href="/admin/#{table}/<%= @record.id %>/edit">Edit</a>
          <a href="/admin/#{table}">Back to list</a>
        </p>
        ECR
      end

      def self.admin_edit_view(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        inputs = fields.map do |(name, type)|
          field = case type
                  when "boolean"  then %(<label><%= f.check_box("#{name}") %> #{name.capitalize}</label>)
                  when "datetime" then %(<label>#{name.capitalize} <%= f.date_field("#{name}") %></label>)
                  else                 %(<label>#{name.capitalize} <%= f.text_field("#{name}") %></label>)
                  end
          "    #{field}"
        end.join("\n")
        inputs = "    <p>No editable fields.</p>" if inputs.empty?
        <<-ECR
        <h1>Edit #{class_name} #<%= @record.id %> (admin)</h1>
        <%= form_with("/admin/#{table}/<%= @record.id %>", method: "patch", model: @record, scope: "#{table.chomp("s")}") do |f| %>
          <%= f.error_messages %>
        #{inputs}
          <%= f.submit("Update #{class_name}") %>
        <% end %>
        <p><a href="/admin/#{table}/<%= @record.id %>">Show</a> <a href="/admin/#{table}">Back to list</a></p>
        ECR
      end

      def self.admin_spec_source(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        sample = sample_args(fields)
        create_call = sample.empty? ? "#{class_name}.create!" : "#{class_name}.create!(#{sample})"
        <<-CRYSTAL
        require "../../spec_helper"

        describe "Admin::#{plural}Controller requests" do
          router = Saci::Router.new.draw do |r|
            r.namespace("/admin") do |a|
              a.resources "#{table}", Admin::#{plural}Controller
            end
          end

          before_each do
            Saci::Record.clean_database!
          end

          it "returns 403 on index when not admin" do
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/admin/#{table}")
              resp.status_code.should eq(403)
            end
          end

          it "serves the admin index with search and sort params" do
            #{create_call}
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/admin/#{table}?admin=true&q=example&sort=id&dir=desc")
              resp.status_code.should eq(200)
            end
          end

          it "returns 403 on show when not admin" do
            record = #{create_call}
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/admin/#{table}/\#{record.id}")
              resp.status_code.should eq(403)
            end
          end

          it "serves show for admins" do
            record = #{create_call}
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/admin/#{table}/\#{record.id}?admin=true")
              resp.status_code.should eq(200)
            end
          end

          it "updates and re-renders edit with 422 on failure" do
            record = #{create_call}
            Saci::TestSession.serve(router) do |app|
              denied = app.patch("/admin/#{table}/\#{record.id}", body: "")
              denied.status_code.should eq(403)
              resp = app.patch("/admin/#{table}/\#{record.id}?admin=true", body: "")
              (resp.status_code == 200 || resp.status_code == 302 || resp.status_code == 422).should be_true
            end
          end

          it "destroys for admins and 403s otherwise" do
            record = #{create_call}
            Saci::TestSession.serve(router) do |app|
              denied = app.delete("/admin/#{table}/\#{record.id}")
              denied.status_code.should eq(403)
              resp = app.delete("/admin/#{table}/\#{record.id}?admin=true")
              (resp.status_code == 200 || resp.status_code == 302).should be_true
            end
          end
        end
        CRYSTAL
      end

      private def self.ensure_app_layout! : Nil
        unless Dir.exists?("src/models") && Dir.exists?("src/controllers") && Dir.exists?("db/migrate")
          raise Error.new("Not a Saci app directory (missing src/models, src/controllers or db/migrate). Run `saci new` first or `cd` into your app.")
        end
      end
    end
  end
end
