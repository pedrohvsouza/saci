require "http/client"
require "uri"

module Saci
  module Storage
    # S3-compatible object storage (AWS S3, MinIO, R2, ...).
    #
    # The service signs requests itself with AWS Signature Version 4 using
    # only the standard library (`HTTP::Client` + `OpenSSL::HMAC`). It is
    # intentionally a small skeleton: upload/download/delete/exists/url are
    # implemented, but multipart uploads, server-side encryption, ACLs and
    # CDN integration are left to application code.
    #
    # ```
    # service = Saci::Storage::S3Service.new(
    #   bucket: "my-app-bucket",
    #   region: "eu-central-1",
    #   access_key_id: ENV["AWS_ACCESS_KEY_ID"],
    #   secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"]
    # )
    # Saci::Storage.register_service("s3", service)
    # ```
    #
    # Credentials can also come from `AWS_ACCESS_KEY_ID`,
    # `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION` and
    # `AWS_ENDPOINT_URL` when the constructor arguments are omitted.
    #
    # Missing credentials/bucket raise `Storage::NotConfigured` on first
    # use, never at class load. `locate` returns nil (there is no local
    # file); use `Blob#url` / `Blob#download` with an S3-backed blob.
    class S3Service < Service
      getter name : String
      getter bucket : String?
      getter region : String
      getter access_key_id : String?
      getter secret_access_key : String?
      getter session_token : String?
      getter endpoint : String

      def initialize(*, @bucket : String? = ENV["AWS_BUCKET"]?,
                     @region : String = ENV.fetch("AWS_REGION", "us-east-1"),
                     @access_key_id : String? = ENV["AWS_ACCESS_KEY_ID"]?,
                     @secret_access_key : String? = ENV["AWS_SECRET_ACCESS_KEY"]?,
                     @session_token : String? = ENV["AWS_SESSION_TOKEN"]?,
                     endpoint : String? = ENV["AWS_ENDPOINT_URL"]?,
                     @name : String = "s3")
        @endpoint = endpoint || "https://s3.#{@region}.amazonaws.com"
      end

      def configured? : Bool
        !@bucket.nil? && !@access_key_id.nil? && !@secret_access_key.nil?
      end

      def upload(data : Bytes | IO | String, filename : String, content_type : String = "application/octet-stream", public : Bool? = nil, key : String? = nil) : String
        ensure_configured!
        bytes = Storage.read_upload(data)
        key ||= Storage.generate_key
        safe_key!(key)
        uri = object_uri(key)
        headers = HTTP::Headers{
          "Content-Type"   => content_type,
          "Content-Length" => bytes.size.to_s,
        }
        response = perform("PUT", uri, headers, bytes)
        unless response.success?
          raise Error.new("S3 upload failed (#{response.status_code}): #{response.body}")
        end
        key
      end

      def download(key : String) : Bytes
        ensure_configured!
        safe_key!(key)
        response = perform("GET", object_uri(key), HTTP::Headers.new)
        raise FileNotFound.new("no such file: #{key}") if response.status_code == 404
        unless response.success?
          raise Error.new("S3 download failed (#{response.status_code}): #{response.body}")
        end
        response.body.to_slice
      end

      def delete(key : String) : Nil
        ensure_configured!
        safe_key!(key)
        response = perform("DELETE", object_uri(key), HTTP::Headers.new)
        # S3 DELETE is idempotent and returns 204; tolerate 404 as success.
        unless response.success? || response.status_code == 404
          raise Error.new("S3 delete failed (#{response.status_code}): #{response.body}")
        end
      end

      def exists?(key : String) : Bool
        ensure_configured!
        safe_key!(key)
        response = perform("HEAD", object_uri(key), HTTP::Headers.new)
        response.status_code == 200
      end

      # Pre-signed GET URL (valid for `expires_in`, max 7 days).
      def url(key : String, base : String = "/files", expires_in : Time::Span = 5.minutes) : String
        ensure_configured!
        safe_key!(key)
        presigned_url(key, expires_in: expires_in)
      end

      # S3 objects are remote; `FilesController` cannot stream them.
      # Serve `Blob#url` (a pre-signed URL) instead.
      def locate(key : String) : StoredFile?
        nil
      end

      # Builds an AWS SigV4 pre-signed GET URL. Public for testing and for
      # applications that need to generate URLs outside a Blob.
      def presigned_url(key : String, expires_in : Time::Span = 5.minutes) : String
        ensure_configured!
        safe_key!(key)
        uri = object_uri(key)
        host = host_header(uri)
        now = Time.utc
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        date_stamp = now.to_s("%Y%m%d")
        scope = "#{date_stamp}/#{@region}/s3/aws4_request"
        seconds = expires_in.total_seconds.to_i.clamp(1, 604800)

        query = {
          "X-Amz-Algorithm"     => "AWS4-HMAC-SHA256",
          "X-Amz-Credential"    => "#{@access_key_id}/#{scope}",
          "X-Amz-Date"          => amz_date,
          "X-Amz-Expires"       => seconds.to_s,
          "X-Amz-SignedHeaders" => "host",
        } of String => String
        if token = @session_token
          query["X-Amz-Security-Token"] = token
        end

        canonical_uri = uri.path
        canonical_query = canonical_query_string(query)
        canonical_headers = "host:#{host}\n"
        canonical_request = [
          "GET", canonical_uri, canonical_query, canonical_headers,
          "host", "UNSIGNED-PAYLOAD",
        ].join("\n")
        string_to_sign = [
          "AWS4-HMAC-SHA256", amz_date, scope,
          Storage::SHA256.hexdigest(canonical_request),
        ].join("\n")
        signature = hex_hmac(signing_key(date_stamp), string_to_sign)
        "#{uri.scheme}://#{host}#{canonical_uri}?#{canonical_query}&X-Amz-Signature=#{signature}"
      end

      private def perform(method : String, uri : URI, headers : HTTP::Headers, body : Bytes? = nil) : HTTP::Client::Response
        payload_hash = body ? Storage::SHA256.hexdigest(body) : Storage::SHA256.hexdigest("")
        sign_request(method, uri, headers, payload_hash)
        tls = uri.scheme == "https" ? true : false
        client = HTTP::Client.new(uri.host.not_nil!, uri.port, tls)
        begin
          path = uri.path
          path += "?#{uri.query}" if uri.query
          client.exec(method, path, headers, body)
        ensure
          client.close
        end
      end

      private def sign_request(method : String, uri : URI, headers : HTTP::Headers, payload_hash : String) : Nil
        host = host_header(uri)
        now = Time.utc
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        date_stamp = now.to_s("%Y%m%d")
        headers["Host"] = host
        headers["x-amz-date"] = amz_date
        headers["x-amz-content-sha256"] = payload_hash
        headers["x-amz-security-token"] = @session_token.not_nil! if @session_token

        canonical_header_names = ["content-type", "host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"]
        canonical_headers = String.build do |io|
          canonical_header_names.sort!.each do |name|
            value = headers[name]?
            next unless value
            io << name << ':' << value.strip << '\n'
          end
        end
        signed_headers = canonical_header_names.select { |name| headers[name]? }.join(";")
        canonical_uri = uri.path
        canonical_query = canonical_query_string(query_pairs(uri.query))
        canonical_request = [
          method, canonical_uri, canonical_query, canonical_headers,
          signed_headers, payload_hash,
        ].join("\n")
        scope = "#{date_stamp}/#{@region}/s3/aws4_request"
        string_to_sign = [
          "AWS4-HMAC-SHA256", amz_date, scope,
          Storage::SHA256.hexdigest(canonical_request),
        ].join("\n")
        signature = hex_hmac(signing_key(date_stamp), string_to_sign)
        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=#{@access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
      end

      private def signing_key(date_stamp : String) : Bytes
        k_date = OpenSSL::HMAC.digest(:sha256, "AWS4#{@secret_access_key}", date_stamp)
        k_region = OpenSSL::HMAC.digest(:sha256, k_date, @region)
        k_service = OpenSSL::HMAC.digest(:sha256, k_region, "s3")
        OpenSSL::HMAC.digest(:sha256, k_service, "aws4_request")
      end

      private def hex_hmac(key : Bytes, data : String) : String
        OpenSSL::HMAC.hexdigest(:sha256, key, data)
      end

      private def object_uri(key : String) : URI
        base = URI.parse(@endpoint)
        prefix = base.path.rstrip("/")
        bucket = @bucket || raise NotConfigured.new("S3Service bucket is not configured")
        # Path-style addressing works on AWS S3, MinIO, R2 and most S3
        # clones without DNS wildcard certificates. Set `endpoint` to the
        # service root (e.g. https://s3.eu-central-1.amazonaws.com).
        # The key is encoded the way SigV4 canonicalizes paths, and the
        # request is sent with that exact path, so the two always agree.
        path = "#{prefix}/#{bucket}/#{S3Service.encode_key(key)}"
        URI.new(scheme: base.scheme, host: base.host, port: base.port, path: path)
      end

      # Percent-encodes every byte of `key` except the unreserved
      # characters and `/` (SigV4 `UriEncode` with slashes kept).
      def self.encode_key(key : String) : String
        String.build do |io|
          URI.encode(key, io) { |byte| URI.unreserved?(byte) || byte == '/'.ord }
        end
      end

      private def host_header(uri : URI) : String
        host = uri.host.not_nil!
        port = uri.port
        if port && ((uri.scheme == "https" && port != 443) || (uri.scheme == "http" && port != 80))
          "#{host}:#{port}"
        else
          host
        end
      end

      private def query_pairs(query : String?) : Array(Tuple(String, String))
        return [] of Tuple(String, String) if query.nil? || query.empty?
        query.split("&").compact_map do |pair|
          key, value = pair.split("=", 2)
          next nil if key.empty?
          {URI.decode_www_form(key), URI.decode_www_form(value || "")}
        end
      end

      private def canonical_query_string(query : Hash(String, String) | Array(Tuple(String, String))) : String
        pairs = query.is_a?(Hash(String, String)) ? query.to_a : query
        encoded = pairs.map { |(key, value)| {S3Service.encode_query(key), S3Service.encode_query(value)} }
        encoded.sort_by! { |(key, value)| {key, value} }
        encoded.map { |(key, value)| "#{key}=#{value}" }.join("&")
      end

      # SigV4 `UriEncode` for query names and values: every byte except
      # the unreserved characters, `/` included.
      def self.encode_query(value : String) : String
        String.build do |io|
          URI.encode(value, io) { |byte| URI.unreserved?(byte) }
        end
      end

      private def safe_key!(key : String) : Nil
        if key.empty? || key.starts_with?("/") || key.includes?("..") ||
           key.each_char.any? { |char| char.control? || char == '\\' || char == '"' }
          raise InvalidUpload.new("invalid object key: #{key.inspect}")
        end
      end

      private def ensure_configured! : Nil
        unless configured?
          raise NotConfigured.new(
            "S3Service is not configured: pass bucket/access_key_id/secret_access_key " \
            "or set AWS_BUCKET/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY"
          )
        end
      end
    end
  end
end
