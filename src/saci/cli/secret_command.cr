module Saci
  module CLI
    # `saci secret` — prints a random secret for SECRET_KEY_BASE.
    module Secret
      def self.run(args : Array(String)) : Int32
        puts generate
        0
      end

      def self.generate : String
        Secrets.generate_secret
      end
    end
  end
end
