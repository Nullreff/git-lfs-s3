module GitLfsS3
  module UploadService
    class UploadRequired < Base
      def self.should_handle?(req, object)
        !object.exists? || object.size != req['size']
      end

      def response
        verify_link = "#{protocol}://#{host}#{File.join(server_path, 'verify?token=1')}"
        {
          '_links' => {
            'upload' => {
              'href' => upload_destination,
              'header' => upload_headers
            },
            'verify' => {
              'href' => verify_link,
            }
          }
        }
      end

      def status
        202
      end

      private

      def upload_destination
        object.presigned_url_with_token(:put)
      end

      def upload_headers
        {'content-type' => ''}
      end
    end
  end
end
