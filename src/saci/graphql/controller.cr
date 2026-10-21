require "json"
require "http/server"
require "../controller"
require "../router"
require "./errors"
require "./executor"
require "./context"

module Saci
  module GraphQL
    class Mount
      getter path : String
      getter schema : Saci::GraphQL::Schema.class
      getter graphiql_path : String?

      def initialize(@path : String, @schema : Saci::GraphQL::Schema.class, @graphiql_path : String?)
      end

      def graphiql? : Bool
        !@graphiql_path.nil?
      end
    end

    MOUNTS          = {} of String => Mount
    GRAPHIQL_MOUNTS = {} of String => Mount
    MOUNT_LOCK      = Mutex.new

    # Mounts the GraphQL endpoint on an existing router.
    #
    # ```
    # router = Saci::Router.new
    # Saci::GraphQL.mount(router, path: "/graphql", schema: AppSchema)
    # ```
    #
    # Registers `POST /graphql`, `GET /graphql?query=...`, and (by default)
    # `GET /graphiql` when the endpoint is `/graphql` (otherwise
    # `<path>/graphiql`). GraphiQL loads React/GraphiQL from a CDN.
    def self.mount(
      router : Saci::Router,
      *,
      path : String = "/graphql",
      schema : Saci::GraphQL::Schema.class,
      graphiql : Bool = true,
    ) : Mount
      endpoint = normalize_path(path)
      graphiql_path = if graphiql
                        endpoint == "/graphql" ? "/graphiql" : "#{endpoint}/graphiql"
                      end
      mount = Mount.new(endpoint, schema, graphiql_path)

      MOUNT_LOCK.synchronize do
        MOUNTS[endpoint] = mount
        GRAPHIQL_MOUNTS[graphiql_path] = mount if graphiql_path
      end

      router.post(endpoint, Controller, :execute)
      router.get(endpoint, Controller, :execute)
      if graphiql_path
        router.get(graphiql_path, Controller, :graphiql)
      end
      mount
    end

    def self.normalize_path(path : String) : String
      value = path.starts_with?("/") ? path : "/#{path}"
      while value.size > 1 && value.ends_with?('/')
        value = value.rchop('/')
      end
      value
    end

    def self.mount_for(path : String) : Mount?
      MOUNTS[normalize_path(path)]?
    end

    def self.graphiql_mount_for(path : String) : Mount?
      GRAPHIQL_MOUNTS[normalize_path(path)]?
    end

    def self.reset_mounts! : Nil
      MOUNT_LOCK.synchronize do
        MOUNTS.clear
        GRAPHIQL_MOUNTS.clear
      end
    end

    # `Saci::Params.build` consumes the request body before the action runs.
    # GraphQL needs the raw document (especially for batched arrays, which the
    # generic params parser intentionally ignores), so rewind the body after
    # params extraction for mounted GraphQL endpoints only.
    class ::Saci::Params
      def self.build(request : HTTP::Request, path_params : Hash(String, String)) : Params
        unless Saci::GraphQL.mount_for(request.path)
          return previous_def
        end

        raw = request.body.try(&.gets_to_end) || ""
        request.body = IO::Memory.new(raw)
        params = previous_def
        request.body = IO::Memory.new(raw)
        params
      end
    end

    # HTTP endpoint shared by every mounted schema. The schema is resolved
    # from the request path registered by `Saci::GraphQL.mount`.
    class Controller < Saci::Controller
      def execute
        mount = Saci::GraphQL.mount_for(request.path)
        unless mount
          write_error("No GraphQL schema mounted at #{request.path}", 404)
          return
        end

        if request.method == "GET"
          execute_get(mount)
        else
          execute_post(mount)
        end
      end

      def graphiql
        mount = Saci::GraphQL.graphiql_mount_for(request.path)
        unless mount
          write_error("No GraphiQL endpoint mounted at #{request.path}", 404)
          return
        end
        response.status_code = 200
        response.content_type = "text/html; charset=utf-8"
        response.print(graphiql_html(mount))
        @performed = true
      end

      private def execute_get(mount : Mount) : Nil
        query = params["query"]?
        if query.nil? || query.strip.empty?
          write_error("No query provided. Use GET ?query=... or POST JSON {query: ...}.", 400)
          return
        end
        variables = parse_variables_param(params["variables"]?)
        if variables.is_a?(JSON::Any) && variables.as_h?.nil?
          write_error("variables must be a JSON object", 400)
          return
        end
        result = mount.schema.execute(
          query,
          variables: variables,
          operation_name: params["operationName"]?,
          request: request,
          controller: self,
        )
        write_result(result, result.parse_error? ? 400 : 200)
      end

      private def execute_post(mount : Mount) : Nil
        body = request.body.try(&.gets_to_end) || ""
        content_type = request.headers["Content-Type"]? || ""

        if content_type.includes?("application/graphql")
          result = mount.schema.execute(body, request: request, controller: self)
          write_result(result, result.parse_error? ? 400 : 200)
          return
        end

        unless content_type.empty? || content_type.includes?("application/json") || content_type.includes?("+json")
          write_error("Content-Type must be application/json", 415)
          return
        end

        payload = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          write_error("Invalid JSON request body: #{error.message}", 400)
          return
        end

        case payload.raw
        when Array
          results = payload.as_a.map do |item|
            result = execute_payload(mount, item)
            JSON::Any.new(result.to_h)
          end
          response.status_code = 200
          response.content_type = "application/json"
          response.print(JSON::Any.new(results).to_json)
          @performed = true
        when Hash
          hash = payload.as_h?
          query = hash.try(&.["query"]?).try(&.as_s?)
          if query.nil? || query.strip.empty?
            write_error("No query provided", 400)
            return
          end
          result = execute_payload(mount, payload)
          write_result(result, result.parse_error? ? 400 : 200)
        else
          write_error("GraphQL request body must be a JSON object or array", 400)
        end
      end

      private def execute_payload(mount : Mount, payload : JSON::Any) : ExecutionResult
        hash = payload.as_h?
        unless hash
          return ExecutionResult.request_error("Each batched operation must be a JSON object")
        end

        query = hash["query"]?.try(&.as_s?)
        if query.nil? || query.strip.empty?
          return ExecutionResult.request_error("No query provided")
        end

        variables = hash["variables"]?
        if variables && variables.as_h?.nil? && !variables.raw.nil?
          return ExecutionResult.request_error("variables must be a JSON object")
        end

        operation_name = hash["operationName"]?.try(&.as_s?)
        mount.schema.execute(
          query,
          variables: variables,
          operation_name: operation_name,
          request: request,
          controller: self,
        )
      end

      private def parse_variables_param(raw : String?) : JSON::Any?
        return nil if raw.nil? || raw.strip.empty?
        begin
          JSON.parse(raw)
        rescue JSON::ParseException
          JSON::Any.new(nil)
        end
      end

      private def write_result(result : ExecutionResult, status : Int32) : Nil
        response.status_code = status
        response.content_type = "application/json"
        response.headers["Cache-Control"] = "no-store"
        response.print(result.to_json)
        @performed = true
      end

      private def write_error(message : String, status : Int32) : Nil
        response.status_code = status
        response.content_type = "application/json"
        response.print(JSON::Any.new({
          "errors" => JSON::Any.new([
            JSON::Any.new({"message" => JSON::Any.new(message)} of String => JSON::Any),
          ]),
        } of String => JSON::Any).to_json)
        @performed = true
      end

      private def graphiql_html(mount : Mount) : String
        endpoint = mount.path
        <<-HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>GraphiQL - #{endpoint}</title>
            <link rel="stylesheet" href="https://unpkg.com/graphiql/graphiql.min.css">
            <style>body { margin: 0; } #graphiql { height: 100vh; }</style>
          </head>
          <body>
            <div id="graphiql">Loading GraphiQL...</div>
            <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
            <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
            <script crossorigin src="https://unpkg.com/graphiql/graphiql.min.js"></script>
            <script>
              const fetcher = GraphiQL.createFetcher({ url: #{endpoint.to_json} });
              const root = ReactDOM.createRoot(document.getElementById("graphiql"));
              root.render(React.createElement(GraphiQL, { fetcher }));
            </script>
          </body>
        </html>
        HTML
      end
    end
  end
end
