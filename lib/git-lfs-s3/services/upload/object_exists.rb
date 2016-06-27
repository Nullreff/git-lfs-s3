module GitLfsS3
  module UploadService
    class ObjectExists < Base
      def self.should_handle?(req, object)
        object.exists? && object.size == req['size']
      end

      def response
        {
          '_links' => {
            'download' => {
              'href' => object.presigned_url_with_token(:get)
            }
          }
        }
      end

      def status
        200
      end
    end
  end
end
