require "crypto/bcrypt"

module Saci
  module Record
    # Cost control for `has_secure_password` (mirrors
    # `ActiveModel::SecurePassword.min_cost` — enable it in specs).
    @@bcrypt_min_cost : Bool = false
    @@bcrypt_mutex = Mutex.new

    def self.bcrypt_min_cost? : Bool
      @@bcrypt_mutex.synchronize { @@bcrypt_min_cost }
    end

    def self.bcrypt_min_cost=(value : Bool) : Nil
      @@bcrypt_mutex.synchronize { @@bcrypt_min_cost = value }
    end

    # bcrypt cost 4 in test mode, default (11) otherwise.
    def self.bcrypt_cost : Int32
      bcrypt_min_cost? ? 4 : Crypto::Bcrypt::DEFAULT_COST
    end

    def self.bcrypt_digest(password : String) : String?
      Crypto::Bcrypt::Password.create(password, cost: bcrypt_cost).to_s
    rescue Crypto::Bcrypt::Error
      # e.g. overlong passwords — validation reports the real problem.
      nil
    end

    def self.bcrypt_verify(digest : String, password : String) : Bool
      Crypto::Bcrypt::Password.new(digest).verify(password)
    rescue Crypto::Bcrypt::Error
      false
    end
  end
end
