module GitLfsS3
  module UploadService
    class Base
      include AwsHelpers
      
      attr_reader :req, :object, :project, :host

      def initialize(req, object, project, host)
        @req = req
        @object = object
        @project = project
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
        GitLfsS3::Application.settings.server_path.gsub(':project', project)
      end

      def protocol
        GitLfsS3::Application.settings.server_ssl ? 'https' : 'http'
      end
    end
  end
end
