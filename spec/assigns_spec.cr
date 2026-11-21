require "spec"
require "../src/saci"

record AssignsPost, title : String

class AssignsDemoController < Saci::Controller
  assigns post: AssignsPost.new("default"), posts: [] of AssignsPost
  assigns label : String = "hi", user : String?

  def show
    @post = AssignsPost.new("hello")
    @posts = [AssignsPost.new("one"), AssignsPost.new("two")]
    render_template "assigns_demo/show", layout: false
  end

  def from_action
    assigns post: AssignsPost.new("from action")
    render_template "assigns_demo/show", layout: false
  end
end

def assigns_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/assigns", AssignsDemoController, :show
    r.get "/assigns/action", AssignsDemoController, :from_action
  end
end

describe "Saci::Controller.assigns" do
  it "pins view-facing slots so templates can call methods on them" do
    Saci::TestSession.serve(assigns_router) do |app|
      response = app.get("/assigns")
      response.status_code.should eq(200)
      response.body.should contain("<h1>hello</h1>")
      response.body.should contain("one, two")
      response.body.should contain("<p>HI</p>")
      response.body.should_not contain("<span>")
    end
  end

  it "assigns from an action to a slot declared in the class body" do
    Saci::TestSession.serve(assigns_router) do |app|
      response = app.get("/assigns/action")
      response.status_code.should eq(200)
      response.body.should contain("<h1>from action</h1>")
    end
  end
end
