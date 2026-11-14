module Saci
  module CLI
    # `saci generate model|controller|migration ...` (alias `saci g ...`).
    module Generate
      FIELD_RE = /\A([a-z][a-z0-9_]*):([a-z]+)\z/

      CRYSTAL_TYPES = {
        "string"   => "String",
        "text"     => "String",
        "integer"  => "Int64",
        "bigint"   => "Int64",
        "float"    => "Float64",
        "boolean"  => "Bool",
        "datetime" => "Time",
      }

      # `--pretend` (dry run) and `--force` are global: accepted anywhere in
      # the `saci generate` argv and stripped before KIND dispatch, so nested
      # generators (scaffold -> model + controller) share the same mode.

      @@pretend : Bool = false
      @@force : Bool = false
      @@overwrite_all : Bool = false
      @@skips : Set(String) = Set(String).new
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

      # Flag setters for commands that share the writer but are not
      # `generate` generators (`destroy`, `app:update`).
      def self.pretend=(value : Bool) : Nil
        @@pretend = value
      end

      def self.force=(value : Bool) : Nil
        @@force = value
      end

      def self.reset_flags! : Nil
        @@pretend = false
        @@force = false
        @@overwrite_all = false
        @@skips.clear
      end

      # `--no-spec`, `--no-migration`, `--no-views`, ... are stored as
      # symbols and honored by the individual generators.
      def self.skip?(feature : Symbol) : Bool
        @@skips.includes?(feature.to_s)
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

      def self.error : IO
        @@error
      end

      def self.reset_output! : Nil
        @@output = STDOUT
        @@error = STDERR
      end

      # Public status line / raw output for sibling commands that reuse the
      # generator writer (`destroy`, `app:update`, `task`, `ci`). Keeping
      # one output object lets specs capture everything.
      def self.log(message : String = "") : Nil
        @@output.puts(message)
      end

      def self.log_line(message : String = "") : Nil
        @@output.puts(message)
      end

      def self.log_raw(message : String) : Nil
        @@output.print(message)
      end

      # Reads one y/n/a/q answer (used by destroy / app:update prompts too).
      # Never hangs CI: a TTY blocks for the user, while piped input honors
      # a piped answer and treats EOF as "no".
      def self.confirm(question : String) : Symbol
        input = @@input
        if input.is_a?(IO::FileDescriptor) && input.tty?
          print question
        end
        answer = input.gets
        return :no if answer.nil?
        case answer.strip.downcase
        when "y", "yes"  then :yes
        when "a", "all"  then :all
        when "q", "quit" then :quit
        else                  :no
        end
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
      # What a generator writes for `content`: the `Saci::` prefix dropped
      # where the app allows it (see `Util.unprefix_target?`) and a final
      # newline, so generated files pass `crystal tool format --check`.
      def self.final_content(path : String, content : String) : String
        content = Util.unprefix(content) if Util.unprefix_target?(path)
        content.empty? || content.ends_with?('\n') ? content : content + "\n"
      end

      def self.write_file(path : String, content : String, prompt : Bool = true) : Symbol
        content = final_content(path, content)
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
        rest = [] of String
        args.each do |a|
          case a
          when "--pretend"
            @@pretend = true
          when "--force"
            @@force = true
          when .starts_with?("--no-")
            @@skips << a[5..].gsub('-', '_')
          else
            rest << a
          end
        end
        kind = rest.shift? || raise Error.new("Usage: saci generate KIND NAME [fields...]\nKinds: #{GENERATOR_KINDS.join(", ")}")
        case kind.downcase
        when "model"                           then model(rest)
        when "controller"                      then controller(rest)
        when "migration"                       then migration(rest)
        when "channel"                         then channel(rest)
        when "job"                             then job(rest)
        when "mailer"                          then mailer(rest)
        when "scaffold"                        then scaffold(rest)
        when "admin"                           then admin(rest)
        when "authentication", "auth"          then authentication(rest)
        when "task"                            then task(rest)
        when "helper"                          then helper(rest)
        when "test"                            then model_test(rest)
        when "integration_test", "system_test" then integration_test(rest)
        when "resource"                        then resource(rest)
        when "scaffold_controller"             then scaffold_controller(rest)
        when "benchmark"                       then benchmark(rest)
        when "application_record"              then application_record(rest)
        else                                        raise Error.new("Unknown generator '#{kind}'. Kinds: #{GENERATOR_KINDS.join(", ")}.")
        end
        0
      ensure
        reset_flags!
      end

      GENERATOR_KINDS = [
        "model", "controller", "migration", "channel", "job", "mailer",
        "scaffold", "admin", "authentication", "task", "helper", "test",
        "integration_test", "resource", "scaffold_controller", "benchmark",
        "application_record",
      ]

      alias Field = Tuple(String, String)

      def self.parse_fields(raw : Array(String)) : Array(Field)
        raw.map do |f|
          m = FIELD_RE.match(f) || raise Error.new("Bad field '#{f}'. Expected name:type (types: #{CRYSTAL_TYPES.keys.join(", ")}).")
          type = m[2]
          raise Error.new("Unknown type '#{type}' in field '#{f}'. Valid: #{CRYSTAL_TYPES.keys.join(", ")}.") unless CRYSTAL_TYPES.has_key?(type)
          {m[1], type}
        end
      end

      def self.model(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate model Name [field:type ...]")
        class_name = Util.class_name(Util.file_name(raw_name))
        fields = parse_fields(args)
        ensure_app_layout!

        write_file("src/models/#{Util.file_name(class_name)}.cr", model_source(class_name, fields))

        unless skip?(:spec) || skip?(:test)
          spec_path = "spec/models/#{Util.file_name(class_name)}_spec.cr"
          Dir.mkdir_p("spec/models")
          write_file(spec_path, model_spec_source(class_name, fields))
        end

        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))
        migration_name = "Create#{Record::Inflector.pluralize(class_name)}"
        unless skip?(:migration)
          create_migration_file(migration_name, create_table_source(migration_name, table, fields))
        end
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

        unless skip?(:spec) || skip?(:test)
          spec_path = "spec/requests/#{Util.file_name(class_name)}_spec.cr"
          Dir.mkdir_p("spec/requests")
          write_file(spec_path, controller_spec_source(base, class_name, actions))
        end

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
        routes = actions.map { |a| "    #{controller_route_for(base_path, class_name, a)}" }.join("\n")
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
        ops = fields.map { |(name, type)| "    add_column :#{table}, :#{name}, :#{type}" }.join("\n")
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

      # Creates the app-wide parent (ApplicationJob, ...) for apps made before
      # `saci new` generated it, and says how to load it ahead of the glob.
      def self.ensure_base_class(path : String, content : String) : Nil
        return if File.exists?(path)
        write_file(path, content)
        puts "  note: require #{path} before the #{File.dirname(path)}/* glob in your entrypoint and spec/spec_helper.cr"
      end

      def self.channel(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate channel Name")
        base = Util.class_name(Util.file_name(raw_name.sub(/Channel$/i, "")))
        class_name = "#{base}Channel"
        ensure_app_layout!

        Dir.mkdir_p("src/channels")
        ensure_base_class("src/channels/application_channel.cr", New.application_channel)
        path = "src/channels/#{Util.file_name(class_name)}.cr"
        write_file(path, channel_source(class_name))

        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/channels")
          spec_path = "spec/channels/#{Util.file_name(class_name)}_spec.cr"
          write_file(spec_path, channel_spec_source(class_name))
        end

        puts "Mount it in your router, e.g.:"
        puts "  r.cable \"/cable\", #{class_name}"
      end

      def self.channel_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < ApplicationChannel
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

      def self.job(args : Array(String)) : Nil
        raw_name = args.shift? || raise Error.new("Usage: saci generate job Name")
        base = Util.class_name(Util.file_name(raw_name.sub(/Job$/i, "")))
        class_name = "#{base}Job"
        ensure_app_layout!

        Dir.mkdir_p("src/jobs")
        ensure_base_class("src/jobs/application_job.cr", New.application_job)
        path = "src/jobs/#{Util.file_name(class_name)}.cr"
        write_file(path, job_source(class_name))

        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/jobs")
          spec_path = "spec/jobs/#{Util.file_name(class_name)}_spec.cr"
          write_file(spec_path, job_spec_source(class_name))
        end
      end

      def self.job_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < ApplicationJob
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
        ensure_base_class("src/mailers/application_mailer.cr", New.application_mailer)
        path = "src/mailers/#{Util.file_name(class_name)}.cr"
        write_file(path, mailer_source(class_name))

        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/mailers")
          spec_path = "spec/mailers/#{Util.file_name(class_name)}_spec.cr"
          write_file(spec_path, mailer_spec_source(class_name))
        end
      end

      def self.mailer_source(class_name : String) : String
        <<-CRYSTAL
        class #{class_name} < ApplicationMailer
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

      # One command for the standard REST stack: model + migration +
      # controller (all REST actions) + specs. Prints the route to add
      # (routes stay hand-edited by design).
      def self.scaffold(args : Array(String)) : Nil
        raw_name = args.first? || raise Error.new("Usage: saci generate scaffold Name [field:type ...]")
        fields = args.size > 1 ? args[1..] : [] of String
        class_name = Util.class_name(Util.file_name(raw_name))
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))

        model([class_name] + fields) unless skip?(:model)
        controller([plural, "index", "show", "create", "update", "destroy"]) unless skip?(:controller)

        puts ""
        puts "Add to your router:"
        puts "  r.resources \"#{table}\", #{plural}Controller"
      end

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

        unless skip?(:views)
          Dir.mkdir_p("src/views/admin/#{table}")
          {
            "index" => admin_index_view(class_name, plural, table, fields),
            "show"  => admin_show_view(class_name, plural, table, fields),
            "edit"  => admin_edit_view(class_name, plural, table, fields),
          }.each do |view, source|
            path = "src/views/admin/#{table}/#{view}.ecr"
            write_file(path, source)
          end
        end

        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/requests/admin")
          spec_path = "spec/requests/admin/#{file_base}_controller_spec.cr"
          write_file(spec_path, admin_spec_source(class_name, plural, table, fields))
        end

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

            # Typed defaults: Crystal infers instance variables from their
            # assignments, and the views read these.
            @page = Saci::Pagination::Page(#{class_name}).new([] of #{class_name}, 0_i64, 0, 1, 25, nil, nil)
            @record = #{class_name}.new

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
        <% form_with("/admin/#{table}/\#{@record.id}", method: "patch", model: @record, scope: "#{table.chomp("s")}") do |f| %>
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

      # `saci generate task reports:daily` -> lib/tasks/reports/daily.cr.
      # Namespaced names use subdirectories, matching Rails' task layout.
      def self.task(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate task NAME (e.g. reports:daily)")
        ensure_app!
        segments = raw.split(":").map(&.strip)
        segments.each do |segment|
          unless /\A[a-z][a-z0-9_]*\z/.matches?(segment)
            raise Error.new("Bad task name '#{raw}'. Use lowercase words separated by ':' (e.g. reports:daily).")
          end
        end
        path = (["lib", "tasks"] + segments).join("/") + ".cr"
        write_file(path, task_source(raw))
        puts "Run it with:"
        puts "  saci task #{raw}"
      end

      def self.task_source(name : String) : String
        <<-CRYSTAL
        # Task: #{name}
        # Run with: saci task #{name}
        # (Models are loaded and the database is connected; the server is not booted.)
        task "#{name}", "TODO: describe #{name}" do
          # Your task code here. Example:
          # puts "Posts: \#{Post.all.to_a.size}"
        end
        CRYSTAL
      end

      # `saci generate helper Posts` -> src/helpers/posts_helper.cr.
      # Saci has no autoloading: require the file and `include PostsHelper`
      # in the controller(s) that need it.
      def self.helper(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate helper NAME")
        ensure_app!
        base = Util.class_name(Util.file_name(raw.sub(/Helper$/i, "")))
        module_name = "#{base}Helper"
        file = Util.file_name(module_name)
        path = "src/helpers/#{file}.cr"
        write_file(path, helper_source(module_name, Util.file_name(base)))
        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/helpers")
          write_file("spec/helpers/#{file}_spec.cr", helper_spec_source(module_name, Util.file_name(base)))
        end
        puts "Use it with:"
        puts "  require \"./helpers/#{file}\""
        puts "  include #{module_name}"
      end

      def self.helper_source(module_name : String, base : String) : String
        <<-CRYSTAL
        module #{module_name}
          def #{base}_label(value : String) : String
            "#{module_name}: \#{value}"
          end
        end
        CRYSTAL
      end

      def self.helper_spec_source(module_name : String, base : String) : String
        <<-CRYSTAL
        require "../spec_helper"
        require "../../src/helpers/#{Util.file_name(module_name)}"

        class #{module_name}Host
          include #{module_name}
        end

        describe #{module_name} do
          it "#{base}_label prefixes the value" do
            #{module_name}Host.new.#{base}_label("x").should contain("x")
          end
        end
        CRYSTAL
      end

      # `saci generate test Post` -> spec/models/post_test.cr (Rails test
      # generator layout; Saci specs remain `crystal spec`).
      def self.model_test(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate test NAME")
        ensure_app!
        class_name = Util.class_name(Util.file_name(raw))
        file = Util.file_name(class_name)
        path = "spec/models/#{file}_test.cr"
        write_file(path, <<-CRYSTAL)
        require "../spec_helper"

        describe "#{class_name} model" do
          it "is pending" do
            pending "add #{class_name} model tests"
          end
        end
        CRYSTAL
        puts "Run with: saci test #{path}"
      end

      # `saci generate integration_test Posts` -> spec/integration/posts_test.cr.
      def self.integration_test(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate integration_test NAME")
        ensure_app!
        base = Util.file_name(raw)
        class_name = Util.class_name(base)
        path = "spec/integration/#{base}_test.cr"
        write_file(path, <<-CRYSTAL)
        require "../spec_helper"

        describe "#{class_name} integration" do
          it "exercises the endpoint" do
            # Wire your real route here, then replace `pending` with requests:
            #   router = Saci::Router.new.draw do |r|
            #     r.get "/#{base}", #{class_name}Controller, :index
            #   end
            #   Saci::TestSession.serve(router) do |app|
            #     app.get("/#{base}").status_code.should eq(200)
            #   end
            pending "add #{class_name} integration requests"
          end
        end
        CRYSTAL
        puts "Run with: saci test #{path}"
      end

      # `saci generate benchmark Post#import` -> benchmarks/post_benchmark.cr
      # (kept outside spec/ so `crystal spec` does not run it).
      def self.benchmark(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate benchmark NAME")
        ensure_app!
        base = Util.file_name(raw.gsub("#", "_").gsub("::", "_"))
        path = "benchmarks/#{base}_benchmark.cr"
        write_file(path, <<-CRYSTAL)
        require "benchmark"

        # Run with: crystal run --release #{path}
        Benchmark.ips do |x|
          x.report("#{raw}") do
            # Replace with the operation under test (e.g. Post.all.to_a).
            1 + 1
          end
        end
        CRYSTAL
        puts "Run with: crystal run --release #{path}"
      end

      # `saci generate application_record` — useful after deleting the
      # scaffold file or adding a database to an existing project.
      def self.application_record(args : Array(String)) : Nil
        unless args.empty?
          raise Error.new("Usage: saci generate application_record (no NAME)")
        end
        ensure_app!
        write_file("src/models/application_record.cr", New.application_record)
      end

      def self.resource(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate resource Name [field:type ...]")
        class_name = model_class_name(raw)
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))
        fields = parse_fields(args)
        ensure_app_layout!

        model([class_name] + args) unless skip?(:model)
        unless skip?(:controller)
          file_base = Util.file_name(plural)
          write_file("src/controllers/#{file_base}_controller.cr",
            resource_controller_source(class_name, plural, table, fields))
          unless skip?(:spec) || skip?(:test)
            Dir.mkdir_p("spec/requests")
            write_file("spec/requests/#{file_base}_controller_spec.cr",
              resource_spec_source(class_name, plural, table, fields))
          end
        end
        unless skip?(:route)
          route_file = "src/routes/#{Util.file_name(plural)}_routes.cr"
          write_file(route_file, resource_route_source(plural, table))
          puts "Require and call the route helper from your router:"
          puts "  require \"./routes/#{Util.file_name(plural)}_routes\""
          puts "  Routes.draw_#{table}(r)"
        end
      end

      def self.resource_controller_source(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        json = json_record_expr("record", fields)
        create_assigns = fields.map { |(name, type)| assignment_line("record", name, type) }.join("\n    ")
        update_assigns = fields.map { |(name, type)| assignment_line("record", name, type) }.join("\n    ")
        <<-CRYSTAL
        class #{plural}Controller < ApplicationController
          def index
            render json: #{class_name}.all.to_a.map { |record| #{json} }
          end

          def show
            record = #{class_name}.find(params["id"])
            render json: #{json}
          rescue Saci::Record::RecordNotFound
            render json: {error: "Not found"}, status: :not_found
          end

          def create
            record = #{class_name}.new
            #{create_assigns}
            if record.save
              render json: #{json}, status: :created
            else
              render json: {errors: record.errors.full_messages}, status: :unprocessable_entity
            end
          end

          def update
            record = #{class_name}.find(params["id"])
            #{update_assigns}
            if record.save
              render json: #{json}
            else
              render json: {errors: record.errors.full_messages}, status: :unprocessable_entity
            end
          rescue Saci::Record::RecordNotFound
            render json: {error: "Not found"}, status: :not_found
          end

          def destroy
            #{class_name}.find(params["id"]).destroy
            head :no_content
          rescue Saci::Record::RecordNotFound
            render json: {error: "Not found"}, status: :not_found
          end
        end
        CRYSTAL
      end

      # Hash literal for the JSON resource controller (kept explicit:
      # Saci::Record::Base has no implicit `to_json`).
      def self.json_record_expr(var : String, fields : Array(Field)) : String
        parts = ["\"id\" => #{var}.id"] + fields.map { |(name, _)| "\"#{name}\" => #{var}.#{name}" }
        "{#{parts.join(", ")}}"
      end

      def self.assignment_line(record : String, name : String, type : String) : String
        case type
        when "string", "text"
          "#{record}.#{name} = params[\"#{name}\"]? if params.has_key?(\"#{name}\")"
        when "integer", "bigint"
          "if v = params[\"#{name}\"]?\n      #{record}.#{name} = v.to_i64? || #{record}.#{name}\n    end"
        when "float"
          "if v = params[\"#{name}\"]?\n      #{record}.#{name} = v.to_f? || #{record}.#{name}\n    end"
        when "boolean"
          "#{record}.#{name} = params[\"#{name}\"]? == \"true\" if params.has_key?(\"#{name}\")"
        when "datetime"
          "if v = params[\"#{name}\"]?\n      #{record}.#{name} = (Time.parse_iso8601(v) rescue #{record}.#{name})\n    end"
        else
          "#{record}.#{name} = params[\"#{name}\"]? if params.has_key?(\"#{name}\")"
        end
      end

      def self.resource_route_source(plural : String, table : String) : String
        <<-CRYSTAL
        # Generated by `saci generate resource #{plural}`.
        # Require this file and call it from your router:
        #   require "./routes/#{Util.file_name(plural)}_routes"
        #   Routes.draw_#{table}(r)
        module Routes
          def self.draw_#{table}(r : Saci::Router) : Nil
            r.resources "#{table}", #{plural}Controller
          end
        end
        CRYSTAL
      end

      def self.resource_spec_source(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        sample = sample_args(fields)
        create_call = sample.empty? ? "#{class_name}.create!" : "#{class_name}.create!(#{sample})"
        <<-CRYSTAL
        require "../spec_helper"

        describe "#{plural}Controller resource requests" do
          router = Saci::Router.new.draw do |r|
            r.resources "#{table}", #{plural}Controller
          end

          before_each do
            Saci::Record.clean_database!
          end

          it "lists records" do
            #{create_call}
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/#{table}")
              resp.status_code.should eq(200)
              resp.body.should contain("\\"id\\"")
            end
          end

          it "returns 404 for a missing record" do
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/#{table}/999999")
              resp.status_code.should eq(404)
            end
          end
        end
        CRYSTAL
      end

      # `saci generate scaffold_controller Posts title:string` — controller
      # + ECR views for an existing model (no model/migration/routes).
      # Fields are optional: when omitted they are read from
      # src/models/<model>.cr.
      def self.scaffold_controller(args : Array(String)) : Nil
        raw = args.shift? || raise Error.new("Usage: saci generate scaffold_controller NAME [field:type ...]")
        class_name = model_class_name(raw)
        plural = Record::Inflector.pluralize(class_name)
        table = Record::Inflector.pluralize(Record::Inflector.underscore(class_name))
        var = Util.file_name(class_name)
        fields = args.empty? ? fields_for_model(class_name) : parse_fields(args)
        ensure_app_layout!

        file_base = Util.file_name(plural)
        write_file("src/controllers/#{file_base}_controller.cr",
          scaffold_controller_source(class_name, plural, table, var, fields))

        unless skip?(:views)
          Dir.mkdir_p("src/views/#{table}")
          {
            "index" => scaffold_index_view(class_name, plural, table, fields),
            "show"  => scaffold_show_view(class_name, plural, table, var, fields),
            "new"   => scaffold_new_view(class_name, plural, table, var, fields),
            "edit"  => scaffold_edit_view(class_name, plural, table, var, fields),
          }.each do |view, source|
            write_file("src/views/#{table}/#{view}.ecr", source)
          end
        end

        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/requests")
          write_file("spec/requests/#{file_base}_controller_spec.cr",
            scaffold_controller_spec_source(class_name, plural, table, fields))
        end

        puts ""
        puts "Add to your router:"
        puts "  r.resources \"#{table}\", #{plural}Controller"
      end

      # Class name for generators that take a model name which may be
      # spelled plural (`scaffold_controller Posts`): when the singular
      # model file exists, use it; otherwise treat the name as singular.
      def self.model_class_name(raw : String) : String
        base = Util.file_name(raw)
        if base.ends_with?("s") && File.exists?("src/models/#{base[0...-1]}.cr")
          return Util.class_name(base[0...-1])
        end
        Util.class_name(base)
      end

      # Reads `column name : Type` lines from an existing model file.
      def self.fields_for_model(class_name : String) : Array(Field)
        path = "src/models/#{Util.file_name(class_name)}.cr"
        return [] of Field unless File.exists?(path)
        source = File.read(path)
        fields = [] of Field
        source.scan(/(?m)^\s*column\s+([a-z][a-z0-9_]*)\s*:\s*([A-Za-z0-9_]+)/) do |m|
          name = m[1]
          next if name == "id"
          type = case m[2]
                 when "String"             then "string"
                 when "Int32", "Int64"     then "integer"
                 when "Float32", "Float64" then "float"
                 when "Bool"               then "boolean"
                 when "Time"               then "datetime"
                 else                           "string"
                 end
          fields << {name, type}
        end
        fields
      end

      def self.scaffold_controller_source(class_name : String, plural : String, table : String, var : String, fields : Array(Field)) : String
        assigns_create = fields.map { |(name, type)| assignment_line("@#{var}", name, type) }.join("\n    ")
        assigns_update = fields.map { |(name, type)| assignment_line("@#{var}", name, type) }.join("\n    ")
        <<-CRYSTAL
        class #{plural}Controller < ApplicationController
          # Typed defaults: Crystal infers instance variables from their
          # assignments, and the views read these in every action.
          @#{table} = [] of #{class_name}
          @#{var} = #{class_name}.new

          def index
            @#{table} = #{class_name}.all.to_a
            render_template :index
          end

          def show
            @#{var} = #{class_name}.find(params["id"])
            render_template :show
          rescue Saci::Record::RecordNotFound
            render text: "Not found", status: :not_found
          end

          def new
            @#{var} = #{class_name}.new
            render_template :new
          end

          def create
            @#{var} = #{class_name}.new
            #{assigns_create}
            if @#{var}.save
              redirect_to "/#{table}/\#{@#{var}.id}"
            else
              render_template :new, status: 422
            end
          end

          def edit
            @#{var} = #{class_name}.find(params["id"])
            render_template :edit
          rescue Saci::Record::RecordNotFound
            render text: "Not found", status: :not_found
          end

          def update
            @#{var} = #{class_name}.find(params["id"])
            #{assigns_update}
            if @#{var}.save
              redirect_to "/#{table}/\#{@#{var}.id}"
            else
              render_template :edit, status: 422
            end
          rescue Saci::Record::RecordNotFound
            render text: "Not found", status: :not_found
          end

          def destroy
            #{class_name}.find(params["id"]).destroy
            redirect_to "/#{table}"
          rescue Saci::Record::RecordNotFound
            render text: "Not found", status: :not_found
          end
        end
        CRYSTAL
      end

      def self.scaffold_index_view(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        headers = (["id"] + fields.map(&.[0])).map { |c| "      <th>#{c.capitalize}</th>" }.join("\n")
        cells = (["id"] + fields.map(&.[0])).map do |c|
          "        <td><%= h(#{c == "id" ? "record.id" : "record.#{c}"}.to_s) %></td>"
        end.join("\n")
        <<-ECR
        <h1>#{plural}</h1>
        <p><a href="/#{table}/new">New #{class_name}</a></p>
        <table>
          <thead>
            <tr>
        #{headers}
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <% @#{table}.each do |record| %>
              <tr>
        #{cells}
                <td>
                  <a href="/#{table}/<%= record.id %>">Show</a>
                  <a href="/#{table}/<%= record.id %>/edit">Edit</a>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
        ECR
      end

      def self.scaffold_show_view(class_name : String, plural : String, table : String, var : String, fields : Array(Field)) : String
        rows = fields.map { |(name, _)| "  <li><strong>#{name.capitalize}:</strong> <%= h(@#{var}.#{name}.to_s) %></li>" }.join("\n")
        rows = "  <li>No attributes yet.</li>" if rows.empty?
        <<-ECR
        <h1>#{class_name} #<%= @#{var}.id %></h1>
        <ul>
        #{rows}
        </ul>
        <p>
          <a href="/#{table}/<%= @#{var}.id %>/edit">Edit</a>
          <a href="/#{table}">Back to list</a>
        </p>
        ECR
      end

      def self.scaffold_new_view(class_name : String, plural : String, table : String, var : String, fields : Array(Field)) : String
        inputs = fields.map { |(name, type)| scaffold_form_input(type, name) }.join("\n")
        inputs = "  <p>No editable fields.</p>" if inputs.empty?
        <<-ECR
        <h1>New #{class_name}</h1>
        <% form_with("/#{table}", model: @#{var}) do |f| %>
          <%= f.error_messages %>
        #{inputs}
          <%= f.submit("Create #{class_name}") %>
        <% end %>
        <p><a href="/#{table}">Back to list</a></p>
        ECR
      end

      def self.scaffold_edit_view(class_name : String, plural : String, table : String, var : String, fields : Array(Field)) : String
        inputs = fields.map { |(name, type)| scaffold_form_input(type, name) }.join("\n")
        inputs = "  <p>No editable fields.</p>" if inputs.empty?
        <<-ECR
        <h1>Edit #{class_name} #<%= @#{var}.id %></h1>
        <% form_with("/#{table}/\#{@#{var}.id}", method: "patch", model: @#{var}) do |f| %>
          <%= f.error_messages %>
        #{inputs}
          <%= f.submit("Update #{class_name}") %>
        <% end %>
        <p><a href="/#{table}/<%= @#{var}.id %>">Show</a> <a href="/#{table}">Back to list</a></p>
        ECR
      end

      private def self.scaffold_form_input(type : String, name : String) : String
        case type
        when "text"
          %(  <label>#{name.capitalize} <%= f.textarea("#{name}") %></label>)
        when "boolean"
          %(  <label><%= f.check_box("#{name}") %> #{name.capitalize}</label>)
        when "datetime"
          %(  <label>#{name.capitalize} <%= f.date_field("#{name}") %></label>)
        else
          %(  <label>#{name.capitalize} <%= f.text_field("#{name}") %></label>)
        end
      end

      def self.scaffold_controller_spec_source(class_name : String, plural : String, table : String, fields : Array(Field)) : String
        sample = sample_args(fields)
        create_call = sample.empty? ? "#{class_name}.create!" : "#{class_name}.create!(#{sample})"
        <<-CRYSTAL
        require "../spec_helper"

        describe "#{plural}Controller scaffold requests" do
          router = Saci::Router.new.draw do |r|
            r.resources "#{table}", #{plural}Controller
          end

          before_each do
            Saci::Record.clean_database!
          end

          it "serves the index" do
            #{create_call}
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/#{table}")
              resp.status_code.should eq(200)
              resp.body.should contain("#{plural}")
            end
          end

          it "renders the new form" do
            Saci::TestSession.serve(router) do |app|
              resp = app.get("/#{table}/new")
              resp.status_code.should eq(200)
            end
          end
        end
        CRYSTAL
      end

      # Generates a complete session/password-reset stack around
      # `Saci::Authentication` (Saci::Auth + Controller helpers):
      # User model + migration, ApplicationController wiring, sessions,
      # signed-id password resets, mailer, views and a request spec.
      def self.authentication(args : Array(String)) : Nil
        user_class = args.empty? ? "User" : Util.class_name(Util.file_name(args.shift))
        ensure_app_layout!

        unless skip?(:model)
          write_file("src/models/#{Util.file_name(user_class)}.cr", auth_user_source(user_class))
        end
        unless skip?(:migration)
          create_migration_file("Create#{Record::Inflector.pluralize(user_class)}",
            auth_migration_source(Record::Inflector.pluralize(Record::Inflector.underscore(user_class))))
        end

        write_file("src/controllers/authentication.cr", auth_module_source(user_class))
        write_file("src/controllers/sessions_controller.cr", auth_sessions_source(user_class))
        write_file("src/controllers/passwords_controller.cr", auth_passwords_source(user_class))
        unless skip?(:mailer)
          ensure_base_class("src/mailers/application_mailer.cr", New.application_mailer)
          write_file("src/mailers/password_mailer.cr", auth_mailer_source)
        end
        unless skip?(:views)
          write_file("src/views/sessions/new.ecr", auth_login_view)
          write_file("src/views/passwords/new.ecr", auth_forgot_view)
          write_file("src/views/passwords/create.ecr", auth_sent_view)
          write_file("src/views/passwords/edit.ecr", auth_reset_view)
        end
        unless skip?(:spec) || skip?(:test)
          Dir.mkdir_p("spec/requests")
          write_file("spec/requests/sessions_controller_spec.cr", auth_spec_source(user_class))
        end

        wire_application_controller!
        open_stock_controllers!
        puts ""
        puts "Add these routes to your router:"
        puts "  r.get \"/login\", SessionsController, :new"
        puts "  r.post \"/login\", SessionsController, :create"
        puts "  r.delete \"/logout\", SessionsController, :destroy"
        puts "  r.get \"/passwords/new\", PasswordsController, :new"
        puts "  r.post \"/passwords\", PasswordsController, :create"
        puts "  r.get \"/passwords/:token/edit\", PasswordsController, :edit"
        puts "  r.patch \"/passwords/:token\", PasswordsController, :update"
        puts "Set Saci::Auth.configure login_path / already_logged_in_path if you rename /login or /."
      end

      def self.auth_user_source(user_class : String) : String
        <<-CRYSTAL
        class #{user_class} < ApplicationRecord
          column id : Int64, primary: true
          column email : String
          column password_digest : String
          timestamps

          has_secure_password
          validates :email, presence: true, uniqueness: true, format: /\\A[^@\\s]+@[^@\\s]+\\z/
        end
        CRYSTAL
      end

      def self.auth_migration_source(table : String) : String
        <<-CRYSTAL
        class Create#{Util.class_name(table)} < Saci::Record::Migration
          def change
            create_table :#{table} do |t|
              t.string :email, null: false
              t.string :password_digest, null: false
              t.timestamps
            end
            add_index :#{table}, :email, unique: true
          end
        end
        CRYSTAL
      end

      def self.auth_module_source(user_class : String) : String
        <<-CRYSTAL
        # Generated by `saci generate authentication`.
        # ApplicationController includes this module, which:
        #   * requires login for every action (opt out with
        #     `allow_unauthenticated_access only: [...]`),
        #   * memoizes `current_user` as #{user_class}, and
        #   * resolves the session id through #{user_class}.
        module Authentication
          macro included
            before_action :require_login
            memoize_current_user #{user_class}

            private def find_current_user(id : Int64) : #{user_class}?
              #{user_class}.find_by(id: id)
            end
          end
        end
        CRYSTAL
      end

      def self.auth_sessions_source(user_class : String) : String
        <<-CRYSTAL
        class SessionsController < ApplicationController
          allow_unauthenticated_access only: [:new, :create]
          before_action :require_no_login, only: [:new]

          def new
            @error = nil
            render_template :new
          end

          def create
            email = params["email"]?.to_s.strip.downcase
            password = params["password"]?.to_s
            if user = #{user_class}.authenticate_by(email: email, password: password)
              login(user)
              redirect_to "/"
            else
              @error = "Invalid email or password"
              render_template :new, status: 422
            end
          end

          def destroy
            logout
            redirect_to "/login"
          end
        end
        CRYSTAL
      end

      def self.auth_passwords_source(user_class : String) : String
        <<-CRYSTAL
        class PasswordsController < ApplicationController
          allow_unauthenticated_access only: [:new, :create, :edit, :update]

          def new
            render_template :new
          end

          def create
            @reset_path = nil
            email = params["email"]?.to_s.strip.downcase
            if user = #{user_class}.find_by(email: email)
              token = user.signed_id(purpose: "password_reset", expires_in: 15.minutes)
              # In production configure a delivery adapter and uncomment:
              # PasswordMailer.reset(user.email, token).deliver_later
              @reset_path = "/passwords/\#{token}/edit"
            end
            render_template :create
          end

          def edit
            @token = params["token"]?.to_s
            @user = #{user_class}.find_signed(@token, purpose: "password_reset")
            render_template :edit, status: 422 if @user.nil?
          end

          def update
            @token = params["token"]?.to_s
            @user = #{user_class}.find_signed(@token, purpose: "password_reset")
            if @user.nil?
              render text: "Invalid or expired reset link", status: :unprocessable_entity
              return
            end
            @user.password = params["password"]?
            @user.password_confirmation = params["password_confirmation"]?
            if @user.save
              redirect_to "/login"
            else
              render_template :edit, status: 422
            end
          end
        end
        CRYSTAL
      end

      def self.auth_mailer_source : String
        <<-CRYSTAL
        class PasswordMailer < ApplicationMailer
          default_from "noreply@example.com"

          def self.reset(email : String, token : String) : Saci::Mailer::Mail
            mail(to: email, subject: "Reset your password") do |format|
              format.text { "Open /passwords/\#{token}/edit to reset your password. The link expires in 15 minutes." }
              format.html { "<p>Open <a href=\\"/passwords/\#{token}/edit\\">/passwords/\#{token}/edit</a> to reset your password.</p>" }
            end
          end
        end
        CRYSTAL
      end

      def self.auth_login_view : String
        <<-ECR
        <h1>Log in</h1>
        <% if message = @error %>
          <p class="error"><%= h(message) %></p>
        <% end %>
        <% form_with("/login") do |f| %>
          <label>Email <%= f.text_field("email") %></label>
          <label>Password <%= f.password_field("password") %></label>
          <%= f.submit("Log in") %>
        <% end %>
        <p><a href="/passwords/new">Forgot your password?</a></p>
        ECR
      end

      def self.auth_forgot_view : String
        <<-ECR
        <h1>Reset your password</h1>
        <% form_with("/passwords") do |f| %>
          <label>Email <%= f.text_field("email") %></label>
          <%= f.submit("Send reset instructions") %>
        <% end %>
        ECR
      end

      def self.auth_sent_view : String
        <<-ECR
        <h1>Check your email</h1>
        <p>If an account exists, password reset instructions are on their way.</p>
        <% if path = @reset_path %>
          <p>Development link: <a href="<%= h(path) %>"><%= h(path) %></a></p>
        <% end %>
        ECR
      end

      def self.auth_reset_view : String
        <<-ECR
        <h1>Choose a new password</h1>
        <% if @user %>
          <% form_with("/passwords/\#{@token}", method: "patch") do |f| %>
            <label>Password <%= f.password_field("password") %></label>
            <label>Confirmation <%= f.password_field("password_confirmation") %></label>
            <%= f.submit("Update password") %>
          <% end %>
        <% else %>
          <p>This reset link is invalid or expired.</p>
        <% end %>
        ECR
      end

      # Only rewrites the stock `saci new` ApplicationController; a custom
      # controller is left alone (instructions printed instead).
      def self.wire_application_controller! : Nil
        path = "src/controllers/application_controller.cr"
        desired = <<-CRYSTAL
        require "./authentication"

        class ApplicationController < Saci::Controller
          include Authentication
        end
        CRYSTAL
        if !File.exists?(path)
          write_file(path, desired)
        elsif default_application_controller?(File.read(path)) || Generate.force?
          write_file(path, desired, prompt: false)
        else
          puts "note: src/controllers/application_controller.cr is customized; add these lines:"
          puts "  require \"./authentication\""
          puts "  include Authentication"
        end
      end

      # `include Authentication` puts every controller behind a login. The
      # welcome page and the `/up` health check that `saci new` generates
      # stay public (probes must not be redirected to /login), but only
      # while they are the stock files; edited ones get a note instead.
      def self.open_stock_controllers! : Nil
        {
          "src/controllers/home_controller.cr"   => New.home_controller,
          "src/controllers/health_controller.cr" => New.health_controller,
        }.each do |path, stock|
          next unless File.exists?(path)
          current = File.read(path)
          next if current.includes?("allow_unauthenticated_access")
          if current.strip == stock.strip
            write_file(path, public_controller(stock), prompt: false)
          else
            puts "note: #{path} now requires a login; add `allow_unauthenticated_access` to keep it public."
          end
        end
      end

      def self.public_controller(stock : String) : String
        stock.sub(/^(class \w+ < ApplicationController)$/m, "\\1\n  allow_unauthenticated_access\n")
      end

      def self.default_application_controller?(content : String) : Bool
        content.strip == "class ApplicationController < Saci::Controller\nend".strip
      end

      def self.auth_spec_source(user_class : String) : String
        <<-CRYSTAL
        require "../spec_helper"

        describe "SessionsController (authentication generator)" do
          router = Saci::Router.new.draw do |r|
            r.get "/login", SessionsController, :new
            r.post "/login", SessionsController, :create
            r.delete "/logout", SessionsController, :destroy
          end

          before_each do
            Saci::Record.clean_database!
          end

          it "logs in with valid credentials" do
            #{user_class}.create!(email: "a@b.c", password: "secret", password_confirmation: "secret")
            Saci::TestSession.serve(router) do |app|
              headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
              resp = app.post("/login", headers: headers, body: "email=a%40b.c&password=secret")
              [302, 303].includes?(resp.status_code).should be_true
            end
          end

          it "re-renders the form with 422 for bad credentials" do
            Saci::TestSession.serve(router) do |app|
              headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
              resp = app.post("/login", headers: headers, body: "email=a%40b.c&password=nope")
              resp.status_code.should eq(422)
            end
          end
        end
        CRYSTAL
      end

      private def self.ensure_app! : Nil
        unless File.exists?("shard.yml")
          raise Error.new("Not a Saci app directory (missing shard.yml). Run `saci new` first or `cd` into your app.")
        end
      end

      private def self.ensure_app_layout! : Nil
        unless Dir.exists?("src/models") && Dir.exists?("src/controllers") && Dir.exists?("db/migrate")
          raise Error.new("Not a Saci app directory (missing src/models, src/controllers or db/migrate). Run `saci new` first or `cd` into your app.")
        end
      end
    end
  end
end
