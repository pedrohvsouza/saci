require "json"
require "uri"

module Saci
  module Storage
    # Signed direct-upload tokens.
    #
    # Browser flow (no cloud credentials ever reach the browser):
    #
    # 1. Server renders a form and calls
    #    `direct_upload_url(filename: file.name, content_type: file.type, byte_size: file.size)`
    #    (or the controller helper of the same name).
    # 2. JavaScript POSTs the file as multipart field `file` to that URL.
    # 3. The endpoint stores a `Blob`, returns `{id, signed_id, url, ...}`.
    # 4. Put `signed_id` in a hidden field; the controller calls
    #    `record.avatar.attach_signed(params["avatar_signed_id"])`.
    #
    # ```
    # const input = document.querySelector("input[type=file]")
    # const form = new FormData()
    # form.append("file", input.files[0])
    # const resp = await fetch(input.dataset.directUploadUrl, {method: "POST", body: form})
    # const blob = await resp.json
    # document.querySelector("#avatar_signed_id").value = blob.signed_id
    # ```
    #
    # Tokens bind filename, content type, exact byte size (when non-zero),
    # target service and a pre-generated key, and expire after 15 minutes
    # by default.
    module DirectUpload
      struct Token
        getter filename : String
        getter content_type : String
        getter byte_size : Int64
        getter key : String
        getter service_name : String

        def initialize(@filename : String, @content_type : String, @byte_size : Int64,
                       @key : String, @service_name : String)
        end

        def to_payload : String
          {
            filename:     @filename,
            content_type: @content_type,
            byte_size:    @byte_size,
            key:          @key,
            service:      @service_name,
          }.to_json
        end

        # Enforces the size/type limits declared when the URL was signed.
        def accepts?(actual_size : Int64, actual_type : String?) : Bool
          return false if actual_size < 0 || actual_size > Storage.max_upload_size
          return false if @byte_size > 0 && actual_size != @byte_size
          actual = (actual_type || "").downcase.split(';', 2)[0].strip
          if !actual.empty? && !@content_type.empty? && actual != @content_type.downcase
            return false
          end
          !Storage.dangerous_content_type?(@content_type)
        end
      end

      def self.generate(filename : String, content_type : String?, byte_size : Int64,
                        service_name : String?, key : String?, expires_in : Time::Span) : String
        safe_name = Storage.sanitize_filename(filename)
        resolved_type = (content_type || Storage.content_type_for(safe_name)).downcase.split(';', 2)[0].strip
        raise UnsafeContentType.new("refusing direct upload of #{resolved_type.inspect}") if Storage.dangerous_content_type?(resolved_type)
        raise UploadTooLarge.new("declared upload exceeds #{Storage.max_upload_size} bytes") if byte_size > Storage.max_upload_size

        resolved_service = (service_name || Storage.service.name).to_s
        # Raises NotConfigured early instead of at upload time.
        Storage.service_named(resolved_service)
        generated_key = key || Storage.generate_key
        raise InvalidUpload.new("invalid storage key: #{generated_key.inspect}") unless Storage.valid_key?(generated_key)

        token = Token.new(safe_name, resolved_type, byte_size, generated_key, resolved_service)
        Storage.sign_message("direct_upload", token.to_payload, expires_in)
      end

      def self.verify(token : String) : Token?
        payload = Storage.verify_message("direct_upload", token)
        return nil unless payload
        hash = JSON.parse(payload).as_h?
        return nil unless hash

        filename = hash["filename"]?.try(&.as_s?)
        content_type = hash["content_type"]?.try(&.as_s?)
        key = hash["key"]?.try(&.as_s?)
        service_name = hash["service"]?.try(&.as_s?) || "local"
        byte_size = hash["byte_size"]?.try(&.as_i64?) || -1_i64
        return nil unless filename && content_type && key
        return nil unless Storage.valid_key?(key)
        return nil if byte_size < 0 || byte_size > Storage.max_upload_size
        return nil if Storage.dangerous_content_type?(content_type)

        Token.new(filename, content_type, byte_size, key, service_name)
      rescue JSON::ParseException
        nil
      end
    end

    # Route path for the direct-upload endpoint. Mount it with:
    #
    # ```
    # r.post "/direct_uploads", Saci::Storage::DirectUploadsController, :create
    # ```
    def self.direct_upload_endpoint : String
      "/direct_uploads"
    end

    # Builds the signed URL described in `DirectUpload`.
    def self.direct_upload_url(*, filename : String,
                               content_type : String? = nil,
                               byte_size : Int64 = 0_i64,
                               service_name : String | Symbol | Nil = nil,
                               key : String? = nil,
                               expires_in : Time::Span = 15.minutes,
                               base : String = direct_upload_endpoint) : String
      token = DirectUpload.generate(filename, content_type, byte_size, service_name.try(&.to_s), key, expires_in)
      separator = base.includes?('?') ? '&' : '?'
      "#{base}#{separator}token=#{URI.encode_www_form(token)}"
    end

    def self.verify_direct_upload(token : String) : DirectUpload::Token?
      DirectUpload.verify(token)
    end

    # Verifies a token and creates the blob. Used by
    # `DirectUploadsController`; call it from custom endpoints too.
    def self.direct_upload(token : String, data : Bytes | IO | String, actual_content_type : String? = nil) : Blob
      verified = DirectUpload.verify(token) || raise InvalidUpload.new("invalid or expired direct upload token")
      bytes = read_upload(data)
      actual_size = bytes.size.to_i64
      unless verified.accepts?(actual_size, actual_content_type)
        raise InvalidUpload.new("upload does not match its signed size/content type")
      end
      validate_upload!(bytes, verified.content_type)
      # Tokens are one-shot: a replay must not create a second blob row
      # pointing at the same pre-generated key.
      target = service_named(verified.service_name)
      if target.exists?(verified.key)
        raise InvalidUpload.new("direct upload token has already been used")
      end
      Blob.create_and_upload!(
        bytes,
        filename: verified.filename,
        content_type: verified.content_type,
        service_name: verified.service_name,
        key: verified.key
      )
    end

    # Accepts `POST /direct_uploads?token=...` with multipart field `file`.
    # Responds `201` with the blob's id/key/signed id/URL, or `422` with
    # `{"error": "..."}` for invalid tokens, oversized files, type
    # mismatches and storage policy violations.
    class DirectUploadsController < Controller
      def create
        token = params["token"]?
        unless token && Storage.verify_direct_upload(token)
          render json: {error: "invalid or expired direct upload token"}, status: :unprocessable_entity
          return
        end

        file = params.file("file")
        unless file
          render json: {error: "missing multipart field 'file'"}, status: :unprocessable_entity
          return
        end

        begin
          blob = Storage.direct_upload(token.not_nil!, file.bytes, file.content_type)
          render json: {
            id:           blob.id,
            key:          blob.key,
            signed_id:    blob.signed_id,
            filename:     blob.filename,
            content_type: blob.content_type,
            byte_size:    blob.byte_size,
            checksum:     blob.checksum,
            url:          blob.url,
          }, status: :created
        rescue ex : Storage::Error
          render json: {error: ex.message}, status: :unprocessable_entity
        end
      end
    end
  end

  class Controller
    # Controller-side convenience for direct-upload forms:
    #
    # ```
    # direct_upload_url(filename: "a.png", content_type: "image/png", byte_size: 1234)
    # ```
    def direct_upload_url(*, filename : String, content_type : String? = nil,
                          byte_size : Int64 = 0_i64, service_name : String | Symbol | Nil = nil,
                          expires_in : Time::Span = 15.minutes,
                          base : String = Saci::Storage.direct_upload_endpoint) : String
      Saci::Storage.direct_upload_url(
        filename: filename,
        content_type: content_type,
        byte_size: byte_size,
        service_name: service_name,
        expires_in: expires_in,
        base: base
      )
    end
  end
end
