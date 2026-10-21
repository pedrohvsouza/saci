require "json"
require "./router"

module Saci
  # Minimal OpenAPI 3 document builder (G302).
  #
  # It intentionally only emits what the router can prove at runtime: HTTP
  # method, path template, and path parameter names. Controller/action names
  # and request/response schemas are not retained by `Saci::Router::Route`,
  # so `operationId`/`summary` are derived from the method and path instead
  # of pretending to know the handler.
  #
  # ```
  # router = Saci::Router.new
  # router.get "/posts/:id", PostsController, :show
  #
  # puts Saci::OpenAPI.json(router, title: "Blog API", version: "1.0.0")
  # File.write("openapi.json", Saci::OpenAPI.json(router))
  # ```
  module OpenAPI
    def self.document(
      router : Saci::Router,
      *,
      title : String = "Saci API",
      version : String = "1.0.0",
      description : String? = nil,
      server_url : String = "/",
    ) : Hash(String, JSON::Any)
      paths = {} of String => Hash(String, JSON::Any)
      router.routes.each do |route|
        template = path_template(route.pattern)
        item = paths[template]? || {} of String => JSON::Any
        item[route.http_method.downcase] = JSON::Any.new(operation(route, template))
        paths[template] = item
      end

      info = {
        "title"   => JSON::Any.new(title),
        "version" => JSON::Any.new(version),
      } of String => JSON::Any
      if description
        info["description"] = JSON::Any.new(description)
      end

      {
        "openapi" => JSON::Any.new("3.0.3"),
        "info"    => JSON::Any.new(info),
        "servers" => JSON::Any.new([
          JSON::Any.new({"url" => JSON::Any.new(server_url)} of String => JSON::Any),
        ]),
        "paths" => JSON::Any.new(paths.transform_values { |item| JSON::Any.new(item) }),
      }
    end

    def self.json(router : Saci::Router, **options) : String
      document(router, **options).to_json
    end

    def self.schema(router : Saci::Router, **options) : Hash(String, JSON::Any)
      document(router, **options)
    end

    # `/posts/:id` -> `/posts/{id}`.
    def self.path_template(pattern : String) : String
      pattern.gsub(/\/:([A-Za-z_][A-Za-z0-9_]*)/, "/{\\1}")
    end

    def self.operation(route : Saci::Router::Route, template : String) : Hash(String, JSON::Any)
      params = route.param_names.uniq.map do |name|
        JSON::Any.new({
          "name"     => JSON::Any.new(name),
          "in"       => JSON::Any.new("path"),
          "required" => JSON::Any.new(true),
          "schema"   => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
        } of String => JSON::Any)
      end

      {
        "operationId" => JSON::Any.new(operation_id(route.http_method, template)),
        "summary"     => JSON::Any.new("#{route.http_method} #{route.pattern}"),
        "tags"        => JSON::Any.new([JSON::Any.new(tag_for(template))]),
        "parameters"  => JSON::Any.new(params),
        "responses"   => JSON::Any.new({
          "200" => JSON::Any.new({"description" => JSON::Any.new("OK")} of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any
    end

    def self.operation_id(method : String, template : String) : String
      suffix = template.gsub(/[^A-Za-z0-9]+/, "_").strip('_')
      suffix = "root" if suffix.empty?
      "#{method.downcase}_#{suffix}"
    end

    def self.tag_for(template : String) : String
      template.split('/').reject(&.empty?).first? || "root"
    end
  end
end
