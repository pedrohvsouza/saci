require "../src/saci"

class HomeController < Saci::Controller
  def index
    render json: {message: "Welcome to Saci", version: Saci::VERSION}
  end
end

class PostsController < Saci::Controller
  before_action :log, except: [:index]

  def index
    render json: [{id: 1, title: "Hello Saci"}]
  end

  def show
    render json: {id: params["id"]? || "?", title: "Post"}
  end

  def create
    name = params["title"]? || "Untitled"
    render json: {id: 2, title: name}, status: :created
  end

  def update
    render json: {id: params["id"]? || "?", title: params["title"]? || "Updated"}
  end

  def destroy
    head :no_content
  end

  private def log
    puts "[PostsController##{action_name}] params=#{params.to_h}"
  end
end

router = Saci::Router.new.draw do |r|
  r.root HomeController, :index
  r.get "/hello", HomeController, :index
  r.resources "posts", PostsController
  r.namespace("/api") do |api|
    api.get "/hello", HomeController, :index
  end
end

app = Saci::Application.new(router)
app.listen(3000)
