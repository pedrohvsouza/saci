require "../job"

module Saci
  module Storage
    # Background jobs used by `Blob#purge_later` / `Blob#analyze_later`.
    # Payloads are ids (JSON boundary), so they survive any job adapter.
    class PurgeJob < Saci::Job::Base
      queue_as :storage

      def perform(payload : JSON::Any) : Nil
        id = payload["blob_id"]?.try(&.as_i64?)
        return if id.nil?
        Blob.find_by(id: id).try(&.purge)
      end
    end

    class AnalyzeJob < Saci::Job::Base
      queue_as :storage

      def perform(payload : JSON::Any) : Nil
        id = payload["blob_id"]?.try(&.as_i64?)
        return if id.nil?
        Blob.find_by(id: id).try(&.analyze)
      end
    end

    class AttachmentPurgeJob < Saci::Job::Base
      queue_as :storage

      def perform(payload : JSON::Any) : Nil
        id = payload["attachment_id"]?.try(&.as_i64?)
        return if id.nil?
        Attachment.find_by(id: id).try(&.purge)
      end
    end
  end
end
