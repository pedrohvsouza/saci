require "spec"
require "json"
require "file"
require "uri"
require "../src/saci"
require "../src/saci/graphql"

GRAPHQL_DB_PATH = "/tmp/opencode/saci_graphql_spec.db"

class GqlUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column email : String

  has_many :posts, class_name: "GqlPost", foreign_key: "gql_user_id"
end

class GqlPost < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column body : String
  column published : Bool
  column status : String
  column gql_user_id : Int64

  belongs_to :author, class_name: "GqlUser", foreign_key: "gql_user_id"
  has_many :comments, class_name: "GqlComment", foreign_key: "gql_post_id"
end

class GqlComment < Saci::Record::Base
  column id : Int64, primary: true
  column body : String
  column gql_post_id : Int64
  column gql_user_id : Int64

  belongs_to :author, class_name: "GqlUser", foreign_key: "gql_user_id"
end

class GqlStatus < Saci::GraphQL::EnumType
  graphql_name "Status"
  description "Publication state"

  value "DRAFT", value: "draft", description: "Not published"
  value "PUBLISHED", value: "published"
end

class GqlUserType < Saci::GraphQL::ObjectType
  source GqlUser
  graphql_name "User"
  description "A blog author"

  field :id, Saci::GraphQL::ID, null: false
  field :name, String, null: false
  field :email, String
  field :posts, [GqlPostType], null: false

  field :postCount, Int, null: false do |user, _args, _ctx|
    user.posts.count
  end
end

class GqlCommentType < Saci::GraphQL::ObjectType
  source GqlComment
  graphql_name "Comment"

  field :id, Saci::GraphQL::ID, null: false
  field :body, String, null: false
  field :authorName, String do |comment, _args, _ctx|
    comment.author.try(&.name)
  end
end

class GqlPostType < Saci::GraphQL::ObjectType
  source GqlPost
  graphql_name "Post"

  field :id, Saci::GraphQL::ID, null: false
  field :title, String, null: false
  field :body, String
  field :published, Boolean, null: false
  field :status, GqlStatus, null: false
  field :author, GqlUserType
  field :comments, [GqlCommentType], null: false

  field :summary, String do |post, _args, _ctx|
    "#{post.title} by #{post.author.try(&.name) || "unknown"}"
  end

  field :requiredTitle, String, null: false do |post, _args, _ctx|
    post.title
  end

  field :nullableBoom, String do |_post, _args, _ctx|
    nil
  end

  field :requiredBoom, String, null: false do |_post, _args, _ctx|
    nil
  end

  field :explode, String do |_post, _args, _ctx|
    raise "resolver exploded"
  end
end

class GqlStatsType < Saci::GraphQL::ObjectType
  source Hash(String, JSON::Any)
  graphql_name "Stats"

  field :users, Int, null: false
  field :posts, Int, null: false
end

class GqlPointType < Saci::GraphQL::ObjectType
  source NamedTuple(x: Int32, y: Int32)
  graphql_name "Point"

  field :x, Int, null: false
  field :y, Int, null: false
end

class GqlPostFilter < Saci::GraphQL::InputObject
  graphql_name "PostFilter"

  argument :published, Boolean
  argument :titleContains, String
end

class GqlQueryType < Saci::GraphQL::ObjectType
  graphql_name "Query"

  field :users, [GqlUserType], null: false do |_source, _args, _ctx|
    GqlUser.order(id: :asc).to_a
  end

  field :user, GqlUserType do
    argument :id, Saci::GraphQL::ID, required: true
    resolve do |_source, args, _ctx|
      GqlUser.find(args["id"].as_s.to_i64)
    end
  end

  field :posts, [GqlPostType], null: false do
    argument :published, Boolean
    resolve do |_source, args, _ctx|
      query = GqlPost.order(id: :asc)
      if published = args["published"]?.try(&.as_bool?)
        query = query.where(published: published)
      end
      query.to_a
    end
  end

  field :post, GqlPostType do
    argument :id, Saci::GraphQL::ID, required: true
    resolve do |_source, args, _ctx|
      GqlPost.find(args["id"].as_s.to_i64)
    end
  end

  field :filteredPosts, [GqlPostType], null: false do
    argument :filter, GqlPostFilter, required: true
    resolve do |_source, args, _ctx|
      filter = args["filter"].as_h
      query = GqlPost.order(id: :asc)
      if published = filter["published"]?.try(&.as_bool?)
        query = query.where(published: published)
      end
      if title = filter["titleContains"]?.try(&.as_s?)
        query = query.where("title LIKE ?", "%#{title}%")
      end
      query.to_a
    end
  end

  field :stats, GqlStatsType, null: false do |_source, _args, _ctx|
    {
      "users" => JSON::Any.new(GqlUser.count),
      "posts" => JSON::Any.new(GqlPost.count),
    } of String => JSON::Any
  end

  field :point, GqlPointType, null: false do |_source, _args, _ctx|
    {x: 3, y: 4}
  end

  field :hello, String, null: false do |_source, _args, _ctx|
    "world"
  end

  field :fromProc, String, null: false,
    resolver: ->(args : Saci::GraphQL::Arguments, ctx : Saci::GraphQL::Context) { "proc" }
end

class GqlMutationType < Saci::GraphQL::ObjectType
  graphql_name "Mutation"

  field :createPost, GqlPostType, null: false do
    argument :title, String, required: true
    argument :authorId, Saci::GraphQL::ID, required: true
    argument :status, GqlStatus, default: "DRAFT"
    resolve do |_source, args, _ctx|
      status = args["status"].as_s
      GqlPost.create!(
        title: args["title"].as_s,
        body: "",
        published: status == "published",
        status: status,
        gql_user_id: args["authorId"].as_s.to_i64,
      )
    end
  end

  field :deletePost, Boolean, null: false do
    argument :id, Saci::GraphQL::ID, required: true
    resolve do |_source, args, _ctx|
      GqlPost.find(args["id"].as_s.to_i64).destroy
      true
    end
  end
end

class GqlTestSchema < Saci::GraphQL::Schema
  query GqlQueryType
  mutation GqlMutationType
end

Saci::GraphQL::Schema.define(GqlDefinedSchema) do
  query GqlQueryType
end

def gql_json(schema : Saci::GraphQL::Schema.class, query : String, variables = nil, operation_name = nil)
  result = schema.execute(query, variables: variables, operation_name: operation_name)
  {JSON.parse(result.to_json), result}
end

def gql_data(result : Saci::GraphQL::ExecutionResult) : JSON::Any
  JSON.parse(result.to_json)["data"]
end

def gql_errors(result : Saci::GraphQL::ExecutionResult) : Array(JSON::Any)
  parsed = JSON.parse(result.to_json)["errors"]?
  parsed ? parsed.as_a : [] of JSON::Any
end

describe "Saci::GraphQL parser" do
  it "parses operations, aliases, arguments, variables, fragments and directives" do
    document = Saci::GraphQL::Language::Parser.parse(<<-GRAPHQL)
    query Feed($id: ID!, $show: Boolean = true) @cached {
      first: user(id: $id) {
        name
        ...UserName
        ... on User @include(if: $show) { email }
      }
      posts(published: true, limit: 2)
    }
    fragment UserName on User {
      name
    }
    GRAPHQL

    document.operations.size.should eq(1)
    operation = document.operations.first
    operation.name.should eq("Feed")
    operation.operation.should eq(:query)
    operation.variables.map(&.name).should eq(["id", "show"])
    operation.variables.last.default_value.should be_a(Saci::GraphQL::Language::BooleanValue)
    operation.directives.first.name.should eq("cached")
    operation.selections.size.should eq(2)

    user_field = operation.selections.first.as(Saci::GraphQL::Language::FieldSelection)
    user_field.alias_name.should eq("first")
    user_field.name.should eq("user")
    user_field.arguments.first.value.should be_a(Saci::GraphQL::Language::VariableValue)
    user_field.selections.size.should eq(3)

    inline = user_field.selections.last.as(Saci::GraphQL::Language::InlineFragment)
    inline.type_condition.should eq("User")
    inline.directives.first.name.should eq("include")

    document.fragments.size.should eq(1)
    document.fragment("UserName").not_nil!.type_condition.should eq("User")
  end

  it "parses every input value literal" do
    document = Saci::GraphQL::Language::Parser.parse(<<-GRAPHQL)
    {
      search(text: "hi", count: 3, ratio: 1.5, live: false, missing: null,
        tags: ["a", "b"], filter: {ids: [1, 2], status: DRAFT}, mode: FAST)
    }
    GRAPHQL

    args = document.operations.first.selections.first.as(Saci::GraphQL::Language::FieldSelection).arguments
    args.map(&.name).should eq(["text", "count", "ratio", "live", "missing", "tags", "filter", "mode"])
    args[1].value.as(Saci::GraphQL::Language::IntValue).value.should eq(3)
    args[2].value.as(Saci::GraphQL::Language::FloatValue).value.should eq(1.5)
    args[3].value.as(Saci::GraphQL::Language::BooleanValue).value.should be_false
    args[4].value.should be_a(Saci::GraphQL::Language::NullValue)
    args[5].value.as(Saci::GraphQL::Language::ListValue).values.size.should eq(2)
    args[6].value.as(Saci::GraphQL::Language::ObjectValue).fields.size.should eq(2)
    args[7].value.as(Saci::GraphQL::Language::EnumValue).name.should eq("FAST")
  end

  it "reports parse errors with line and column" do
    error = expect_raises(Saci::GraphQL::Language::ParseError) do
      Saci::GraphQL::Language::Parser.parse("query Broken {\n  user(id: ) {\n    id\n  }\n}")
    end
    error.line.should eq(2)
    error.column.should be > 1
    error.message.not_nil!.should contain("Expected a value")
  end

  it "rejects unterminated selection sets" do
    error = expect_raises(Saci::GraphQL::Language::ParseError) do
      Saci::GraphQL::Language::Parser.parse("{ user { id }")
    end
    error.message.not_nil!.should contain("Unterminated")
  end
end

describe "Saci::GraphQL executor" do
  before_all do
    File.delete(GRAPHQL_DB_PATH) if File.exists?(GRAPHQL_DB_PATH)
    Saci::Record::Base.connection = DB.open("sqlite3://#{GRAPHQL_DB_PATH}")
    db = Saci::Record.connection
    db.exec("CREATE TABLE gql_users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT)")
    db.exec("CREATE TABLE gql_posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT, published INTEGER, status TEXT, gql_user_id INTEGER)")
    db.exec("CREATE TABLE gql_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT, gql_post_id INTEGER, gql_user_id INTEGER)")

    ada = GqlUser.create!(name: "Ada", email: "ada@example.com")
    grace = GqlUser.create!(name: "Grace", email: "grace@example.com")
    first = GqlPost.create!(title: "Hello GraphQL", body: "intro", published: true, status: "published", gql_user_id: ada.id.not_nil!)
    second = GqlPost.create!(title: "Draft post", body: "wip", published: false, status: "draft", gql_user_id: grace.id.not_nil!)
    GqlComment.create!(body: "Nice!", gql_post_id: first.id.not_nil!, gql_user_id: grace.id.not_nil!)
    GqlComment.create!(body: "Thanks", gql_post_id: first.id.not_nil!, gql_user_id: ada.id.not_nil!)
  end

  after_all do
    Saci::Record.connection.close
  end

  it "executes a simple query and a proc resolver" do
    result = GqlTestSchema.execute("{ hello fromProc }")
    result.errors.should be_empty
    gql_data(result)["hello"].should eq("world")
    gql_data(result)["fromProc"].should eq("proc")
  end

  it "resolves nested records and has_many associations" do
    result = GqlTestSchema.execute(<<-GRAPHQL)
    {
      users {
        id
        name
        posts { id title comments { body authorName } }
      }
    }
    GRAPHQL
    result.errors.should be_empty
    users = gql_data(result)["users"].as_a
    users.size.should eq(2)
    users[0]["name"].should eq("Ada")
    users[0]["posts"].as_a.size.should eq(1)
    users[0]["posts"][0]["comments"].as_a.size.should eq(2)
  end

  it "substitutes variables and coerces arguments" do
    result = GqlTestSchema.execute(
      "query One($id: ID!) { user(id: $id) { id name posts { title } } }",
      variables: JSON.parse(%({"id": "2"}))
    )
    result.errors.should be_empty
    user = gql_data(result)["user"]
    user["name"].should eq("Grace")
    user["posts"].as_a.map(&.["title"]).should eq(["Draft post"])
  end

  it "supports aliases, named fragments and inline fragments" do
    result = GqlTestSchema.execute(<<-GRAPHQL)
    query {
      first: user(id: 1) { ...UserName }
      second: user(id: 2) { ... on User { name } }
    }
    fragment UserName on User { id name }
    GRAPHQL
    result.errors.should be_empty
    data = gql_data(result)
    data["first"]["name"].should eq("Ada")
    data["second"]["name"].should eq("Grace")
  end

  it "applies @skip and @include using variables" do
    result = GqlTestSchema.execute(
      "query($show: Boolean!) { hello @include(if: $show) user: user(id: 1) { name @skip(if: $show) } }",
      variables: JSON.parse(%({"show": true}))
    )
    result.errors.should be_empty
    data = gql_data(result)
    data["hello"].should eq("world")
    data["user"].as_h.has_key?("name").should be_false
  end

  it "filters with enum and input-object arguments" do
    result = GqlTestSchema.execute(<<-GRAPHQL)
    {
      filteredPosts(filter: {published: false, titleContains: "Draft"}) { title status }
    }
    GRAPHQL
    result.errors.should be_empty
    posts = gql_data(result)["filteredPosts"].as_a
    posts.size.should eq(1)
    posts[0]["title"].should eq("Draft post")
    posts[0]["status"].should eq("DRAFT")
  end

  it "resolves Hash and NamedTuple sources" do
    result = GqlTestSchema.execute("{ stats { users posts } point { x y } }")
    result.errors.should be_empty
    data = gql_data(result)
    data["stats"]["users"].should eq(2)
    data["stats"]["posts"].as_i.should eq(2)
    data["point"]["x"].should eq(3)
    data["point"]["y"].should eq(4)
  end

  it "returns errors for unknown fields and runtime exceptions" do
    result = GqlTestSchema.execute("{ nope hello }")
    result.errors.size.should eq(1)
    gql_data(result)["nope"].raw.should be_nil
    gql_data(result)["hello"].should eq("world")

    result = GqlTestSchema.execute("{ post(id: 1) { explode } }")
    result.errors.size.should eq(1)
    result.errors.first.message.should contain("resolver exploded")
    result.errors.first.path.should eq(["post", "explode"])
  end

  it "propagates null from non-null fields" do
    result = GqlTestSchema.execute("{ post(id: 1) { nullableBoom requiredTitle } }")
    result.errors.should be_empty
    gql_data(result)["post"]["nullableBoom"].raw.should be_nil
    gql_data(result)["post"]["requiredTitle"].should eq("Hello GraphQL")

    result = GqlTestSchema.execute("{ post(id: 1) { requiredBoom } }")
    result.errors.size.should eq(1)
    gql_data(result)["post"].raw.should be_nil

    result = GqlTestSchema.execute("{ requiredBoom: post(id: 1) { requiredTitle } }")
    result.errors.should be_empty
  end

  it "executes mutations serially" do
    result = GqlTestSchema.execute(<<-GRAPHQL, variables: JSON.parse(%({"author":"1"})))
    mutation Create($author: ID!) {
      first: createPost(title: "Created one", authorId: $author, status: PUBLISHED) { id title status published }
      second: createPost(title: "Created two", authorId: $author) { id title status published }
    }
    GRAPHQL
    result.errors.should be_empty
    data = gql_data(result)
    data["first"]["title"].should eq("Created one")
    data["first"]["status"].should eq("PUBLISHED")
    data["first"]["published"].should be_true
    data["second"]["status"].should eq("DRAFT")
    data["second"]["published"].should be_false
    data["second"]["id"].as_s.to_i.should be > data["first"]["id"].as_s.to_i

    result = GqlTestSchema.execute("mutation { deletePost(id: 4) }")
    result.errors.should be_empty
    gql_data(result)["deletePost"].should be_true
  end

  it "can select an operation by name" do
    query = "query One { hello } query Two { users { name } }"
    result = GqlTestSchema.execute(query, operation_name: "Two")
    result.errors.should be_empty
    gql_data(result)["users"].as_a.size.should eq(2)

    result = GqlTestSchema.execute(query)
    result.errors.size.should eq(1)
    result.errors.first.message.should contain("operation name")
  end

  it "supports __typename and minimal introspection" do
    result = GqlTestSchema.execute(<<-GRAPHQL)
    {
      __typename
      __type(name: "Post") {
        kind
        name
        fields { name type { kind name ofType { kind name } } }
      }
    }
    GRAPHQL
    result.errors.should be_empty
    data = gql_data(result)
    data["__typename"].should eq("Query")
    data["__type"]["kind"].should eq("OBJECT")
    data["__type"]["name"].should eq("Post")
    data["__type"]["fields"].as_a.map(&.["name"]).should contain("title")
  end

  it "runs the full GraphiQL introspection query" do
    result = Saci::GraphQL.introspect(GqlTestSchema)
    result.errors.should be_empty
    schema = gql_data(result)["__schema"]
    schema["queryType"]["name"].should eq("Query")
    schema["mutationType"]["name"].should eq("Mutation")
    schema["types"].as_a.map(&.["name"]).should contain("Post")
    schema["directives"].as_a.map(&.["name"]).should contain("include")
  end

  it "supports Schema.define" do
    result = GqlDefinedSchema.execute("{ hello }")
    result.errors.should be_empty
    gql_data(result)["hello"].should eq("world")
  end

  it "returns a parse error result from Schema.execute" do
    result = GqlTestSchema.execute("{ hello")
    result.parse_error?.should be_true
    result.errors.first.message.not_nil!.should contain("Unterminated")
  end
end

def gql_http_router : Saci::Router
  Saci::Router.new.draw do |router|
    Saci::GraphQL.mount(router, path: "/graphql", schema: GqlTestSchema)
  end
end

describe "Saci::GraphQL HTTP endpoint" do
  it "serves POST JSON queries with variables" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.post("/graphql",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"query":"query($id: ID!){ user(id: $id){ name } }","variables":{"id":"1"}}))
      response.status_code.should eq(200)
      response.headers["Content-Type"].should contain("application/json")
      JSON.parse(response.body)["data"]["user"]["name"].should eq("Ada")
    end
  end

  it "serves GET queries" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.get("/graphql?query=#{URI.encode_www_form("{ hello }")}")
      response.status_code.should eq(200)
      JSON.parse(response.body)["data"]["hello"].should eq("world")
    end
  end

  it "returns 400 for syntax errors" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.post("/graphql",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"query":"{ hello"}))
      response.status_code.should eq(400)
      errors = JSON.parse(response.body)["errors"].as_a
      errors.first["message"].as_s.should contain("Unterminated")
    end
  end

  it "returns 200 with errors for execution failures" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.post("/graphql",
        HTTP::Headers{"Content-Type" => "application/json"},
        %({"query":"{ nope }"}))
      response.status_code.should eq(200)
      JSON.parse(response.body)["errors"].as_a.size.should eq(1)
    end
  end

  it "returns 400 when the query is missing" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.post("/graphql", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
      response.status_code.should eq(400)
    end
  end

  it "batches Apollo-style operations" do
    body = <<-JSON
    [
      {"query":"{ hello }"},
      {"query":"query($id: ID!){ user(id: $id){ name } }","variables":{"id":"2"}},
      {"query":"{ broken"}
    ]
    JSON
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.post("/graphql", HTTP::Headers{"Content-Type" => "application/json"}, body)
      response.status_code.should eq(200)
      payload = JSON.parse(response.body).as_a
      payload.size.should eq(3)
      payload[0]["data"]["hello"].should eq("world")
      payload[1]["data"]["user"]["name"].should eq("Grace")
      payload[2]["errors"].as_a.size.should eq(1)
    end
  end

  it "serves GraphiQL HTML from the CDN" do
    Saci::TestSession.serve(gql_http_router) do |app|
      response = app.get("/graphiql")
      response.status_code.should eq(200)
      response.headers["Content-Type"].should contain("text/html")
      response.body.should contain("graphiql.min.js")
      response.body.should contain("/graphql")
    end
  end
end
