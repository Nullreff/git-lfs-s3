module GitLfsS3
  module UploadService
    class Base
      include AwsHelpers
      
      attr_reader :req, :object, :project_guid, :host

      def initialize(req, object, project_guid, host)
        @req = req
        @object = object
        @project_guid = project_guid
        @host = host
      end

      def response
        raise "Override"
      end

      def status
        raise "Override"
      end

      private

      def server_path
        GitLfsS3::Application.settings.server_path.gsub(':project_guid', project_guid)
      end

      def protocol
        GitLfsS3::Application.settings.server_ssl ? 'https' : 'http'
      end
    end
  end
end
