require "spec"
require "../src/saci"

# Bounds given as constants must show their value, not the constant's name.
class ValidationMessageProbe < Saci::Record::Base
  NICKNAME_MIN =  3
  NICKNAME_MAX =  8
  SCORE_FLOOR  =  1
  SCORE_CEIL   = 10

  table "validation_message_probes"
  column id : Int64, primary: true
  column nickname : String
  column bio : String
  column score : Int32

  validates :nickname, min_length: NICKNAME_MIN, max_length: NICKNAME_MAX
  validates :bio, length: {in: NICKNAME_MIN..NICKNAME_MAX}, allow_blank: true
  validates :score, numericality: {greater_than_or_equal_to: SCORE_FLOOR, less_than: SCORE_CEIL}, allow_nil: true
end

describe "validation messages with constant bounds" do
  it "interpolates the constant's value into length messages" do
    long = ValidationMessageProbe.new(nickname: "much-too-long")
    long.valid?.should be_false
    long.errors["nickname"].should eq(["is too long (maximum is 8 characters)"])

    short = ValidationMessageProbe.new(nickname: "ab", bio: "x")
    short.valid?.should be_false
    short.errors["nickname"].should eq(["is too short (minimum is 3 characters)"])
    short.errors["bio"].should eq(["is too short (minimum is 3 characters)"])
  end

  it "interpolates the constant's value into numericality messages" do
    low = ValidationMessageProbe.new(nickname: "valid", score: 0)
    low.valid?.should be_false
    low.errors["score"].should eq(["must be greater than or equal to 1"])

    high = ValidationMessageProbe.new(nickname: "valid", score: 10)
    high.valid?.should be_false
    high.errors["score"].should eq(["must be less than 10"])
  end
end
