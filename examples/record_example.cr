require "../src/saci"

Saci::Record.connection = DB.open("sqlite3://./saci_example.db")

class CreateUsers < Saci::Record::Migration
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.integer :age
      t.boolean :admin, default: false
      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end

class CreatePosts < Saci::Record::Migration
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.integer :views, default: 0
      t.boolean :published, default: false
      t.integer :user_id
      t.timestamps
    end
  end
end

class User < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column email : String
  column age : Int32
  column admin : Bool, default: false
  timestamps

  validates :name, presence: true, min_length: 2
  validates :email, presence: true, format: /@/, uniqueness: true

  has_many :posts
end

class Post < Saci::Record::Base
  column id : Int64, primary: true
  column title : String
  column views : Int64
  column published : Bool, default: false
  column user_id : Int64
  timestamps

  validates :title, presence: true

  belongs_to :user
end

db = Saci::Record.connection.as(DB::Database)
Saci::Record::Migrator.migrate(db, [CreateUsers, CreatePosts] of Saci::Record::Migration.class)

user = User.create!(name: "Ada", email: "ada@example.com", age: 36)
Post.create!(title: "Hello Saci", views: 500, published: true, user_id: user.id)
Post.create!(title: "Draft", views: 3, published: false, user_id: user.id)

puts "Users: #{User.count}"
puts "Published: #{Post.where(published: true).map(&.title).inspect}"
puts "Ada's posts: #{user.posts.map(&.title).inspect}"
puts "Top post: #{Post.order(views: :desc).first.not_nil!.title}"

bad = User.new(name: "X", email: "nope")
puts "Valid? #{bad.valid?} — #{bad.errors.full_messages.inspect}"
