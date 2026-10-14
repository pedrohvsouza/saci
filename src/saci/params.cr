module Saci
  # Rails-like `params` hash: merges path params, query string and request body
  # (JSON + URL-encoded forms). All keys/values are stored as Strings.
  class Params
    getter values : Hash(String, String)

    def initialize(@values : Hash(String, String) = {} of String => String)
    end

    # Build params from an incoming request plus already-extracted path params.
    def self.build(request : HTTP::Request, path_params : Hash(String, String)) : Params
      values = {} of String => String
      path_params.each { |k, v| values[k] = v }

      # Query string
      if query = request.query
        URI::Params.parse(query).each do |key, value|
          values[key] = value
        end
      end

      # Body (POST/PUT/PATCH)
      if body = request.body
        content_type = request.headers["Content-Type"]? || ""
        raw = body.gets_to_end
        unless raw.empty?
          if content_type.includes?("application/json")
            begin
              JSON.parse(raw).as_h.each do |k, v|
                values[k] = case v.raw
                            when String then v.as_s
                            when Nil    then ""
                            else             v.to_json
                            end
              end
            rescue JSON::ParseException
              # Invalid JSON -> ignore body, like Rails would 400 later.
              # Keep query/path params only.
            end
          elsif content_type.includes?("application/x-www-form-urlencoded")
            URI::Params.parse(raw).each do |key, value|
              values[key] = value
            end
          end
        end
      end

      new(values)
    end

    def [](key : String | Symbol) : String
      @values[key.to_s]
    end

    def []?(key : String | Symbol) : String?
      @values[key.to_s]?
    end

    def has_key?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s)
    end

    def fetch(key : String | Symbol, default : String? = nil) : String?
      @values.fetch(key.to_s, default)
    end

    # Like Rails `params.require(:user)` — raises when missing/blank.
    def require(key : String | Symbol) : String
      value = @values[key.to_s]?
      if value.nil? || value.empty?
        raise ParameterMissing.new("param is missing or empty: #{key}")
      end
      value
    end

    # Like Rails `params.permit(:a, :b)` — returns a filtered Hash.
    def permit(*keys : String | Symbol) : Hash(String, String)
      allowed = keys.map(&.to_s).to_set
      @values.select { |k, _| allowed.includes?(k) }
    end

    def int(key : String | Symbol, default : Int32? = nil) : Int32?
      raw = @values[key.to_s]?
      return default if raw.nil?
      raw.to_i?(default.nil? ? nil : default)
    rescue
      default
    end

    def to_h : Hash(String, String)
      @values.dup
    end

    # Copy with sensitive values filtered (see `Saci.filter_parameters`).
    def filtered : Hash(String, String)
      Saci.filter_params(to_h)
    end

    def each(&block : String, String ->)
      @values.each { |k, v| block.call(k, v) }
    end

    def empty? : Bool
      @values.empty?
    end

    def to_s(io : IO) : Nil
      @values.to_s(io)
    end
  end
end
