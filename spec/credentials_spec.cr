require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/credentials_command"

CRED_TMP = "/tmp/opencode/saci-creds"

def with_cred_env(& : ->) : Nil
  FileUtils.rm_rf(CRED_TMP)
  Dir.mkdir_p(CRED_TMP)
  old_key = ENV["RAILS_MASTER_KEY"]?
  old_secret = ENV["SECRET_KEY_BASE"]?
  ENV.delete("RAILS_MASTER_KEY")
  ENV.delete("SECRET_KEY_BASE")
  begin
    yield
  ensure
    if restored = old_key
      ENV["RAILS_MASTER_KEY"] = restored
    else
      ENV.delete("RAILS_MASTER_KEY")
    end
    if restored = old_secret
      ENV["SECRET_KEY_BASE"] = restored
    else
      ENV.delete("SECRET_KEY_BASE")
    end
    FileUtils.rm_rf(CRED_TMP)
  end
end

describe Saci::MessageEncryptor do
  it "round-trips AES-256-GCM envelopes" do
    key = Bytes.new(32)
    Random::Secure.random_bytes(key)
    envelope = Saci::MessageEncryptor.encrypt_and_sign(key, "top-secret".to_slice)
    String.new(Saci::MessageEncryptor.decrypt_and_verify(key, envelope)).should eq("top-secret")
  end

  it "rejects tampered envelopes and bad keys" do
    key = Bytes.new(32)
    Random::Secure.random_bytes(key)
    envelope = Saci::MessageEncryptor.encrypt_and_sign(key, "x".to_slice)
    parts = envelope.split("--")
    tampered = parts.dup
    tampered[1] = parts[1][0...-2] + (parts[1][-2..] == "AA" ? "BB" : "AA")
    expect_raises(Saci::MessageEncryptor::Error) do
      Saci::MessageEncryptor.decrypt_and_verify(key, tampered.join("--"))
    end
    expect_raises(Saci::MessageEncryptor::Error) { Saci::MessageEncryptor.decrypt_and_verify(key, "garbage") }
    other = Bytes.new(32)
    Random::Secure.random_bytes(other)
    expect_raises(Saci::MessageEncryptor::Error) { Saci::MessageEncryptor.decrypt_and_verify(other, envelope) }
    expect_raises(Saci::MessageEncryptor::Error) { Saci::MessageEncryptor.encrypt_and_sign(Bytes.new(16), "x".to_slice) }
  end
end

def y_hash(pairs : Hash(String, String)) : YAML::Any
  YAML::Any.new(pairs.to_h { |k, v| {YAML::Any.new(k), YAML::Any.new(v)} })
end

describe Saci::Credentials do
  it "writes, reads and digs nested values" do
    with_cred_env do
      key_path = File.join(CRED_TMP, "master.key")
      file_path = File.join(CRED_TMP, "credentials.yml.enc")
      File.write(key_path, Saci::Credentials.generate_key + "\n")
      Saci::Credentials.key_path = key_path
      begin
        data = {"api_key" => YAML::Any.new("ABC"), "aws" => y_hash({"secret" => "XYZ"})}
        Saci::Credentials.write(data, file_path)
        Saci::Credentials.dig("api_key", file_path).should eq("ABC")
        Saci::Credentials.dig("aws.secret", file_path).should eq("XYZ")
        Saci::Credentials.dig("aws.missing", file_path).should be_nil
        Saci::Credentials.dig("nope", file_path).should be_nil
      ensure
        Saci::Credentials.key_path = "config/master.key"
      end
    end
  end

  it "fails fast on missing or malformed master keys" do
    with_cred_env do
      Saci::Credentials.key_path = File.join(CRED_TMP, "absent.key")
      begin
        expect_raises(Exception, /aster key/) do
          Saci::Credentials.master_key
        end
        bad = File.join(CRED_TMP, "bad.key")
        File.write(bad, "not-hex")
        Saci::Credentials.key_path = bad
        expect_raises(Exception, /aster key/) do
          Saci::Credentials.master_key
        end
      ensure
        Saci::Credentials.key_path = "config/master.key"
      end
    end
  end

  it "feeds secret_key_base from the credentials file" do
    with_cred_env do
      Saci::Secrets.reset_secret_key_base!
      begin
        Dir.cd(CRED_TMP) do
          Dir.mkdir_p("config")
          File.write("config/master.key", Saci::Credentials.generate_key + "\n")
          Saci::Credentials.write({"secret_key_base" => YAML::Any.new("creds-secret-1")}, "config/credentials.yml.enc")
          Saci::Secrets.secret_key_base.should eq("creds-secret-1")
        end
      ensure
        Saci::Secrets.reset_secret_key_base!
      end
    end
  end
end

describe "Saci::CLI::Credentials" do
  it "shows, edits and generates keys" do
    with_cred_env do
      Dir.cd(CRED_TMP) do
        Dir.mkdir_p("config")
        Saci::CLI::Credentials.run([] of String, "keygen").should eq(0)
        File.exists?("config/master.key").should be_true

        Saci::Credentials.write({"api_key" => YAML::Any.new("SHOWME")})
        Saci::CLI::Credentials.run([] of String, "show").should eq(0)

        Saci::CLI::Credentials.run(["true"], "edit").should eq(0)
        Saci::Credentials.dig("api_key").should eq("SHOWME")
      end
    end
  end
end
