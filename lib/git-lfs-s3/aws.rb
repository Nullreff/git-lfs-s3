module GitLfsS3
  module AwsHelpers
    def s3
      @s3 ||= Aws::S3::Client.new({
        region: aws_region,
        access_key_id: aws_access_key_id,
        secret_access_key: aws_secret_access_key
      })
    end

    def bucket_name
      GitLfsS3::Application.settings.s3_bucket
    end

    def bucket
      @bucket = Aws::S3::Bucket.new(name: bucket_name, client: s3)
    end

    def object_data(project, oid)
      bucket.object("#{project}/#{oid}")
    end

    def aws_region
      GitLfsS3::Application.settings.aws_region
    end

    def aws_access_key_id
      GitLfsS3::Application.settings.aws_access_key_id
    end

    def aws_secret_access_key
      GitLfsS3::Application.settings.aws_secret_access_key
    end
  end
end

module Aws
  module S3

    # Modified from the code at
    # https://github.com/aws/aws-sdk-ruby/blob/master/aws-sdk-resources/lib/aws-sdk-resources/services/s3/object.rb
    # License: https://github.com/aws/aws-sdk-ruby/blob/master/LICENSE.txt
    class Object
      def presigned_url_with_token(http_method)
        presigner = Aws::S3::Presigner.new(client: client)
        presigner.presigned_url_with_token("#{http_method.downcase}_object", {
          bucket: bucket_name,
          key: key,
        })
      end
    end

    # Modified from the code at
    # https://github.com/aws/aws-sdk-ruby/blob/master/aws-sdk-core/lib/aws-sdk-core/s3/presigner.rb
    # License: https://github.com/aws/aws-sdk-ruby/blob/master/LICENSE.txt
    class Presigner
      def presigned_url_with_token(method, params = {})
        scheme = @client.config.endpoint.scheme
        req = @client.build_request(method, params)

        sign_request_with_token(req, FIFTEEN_MINUTES, scheme)
        req.send_request.data
      end

    private

      def sign_request_with_token(req, expires_in, scheme)
        req.handlers.remove(Plugins::S3RequestSigner::SigningHandler)
        req.handlers.remove(Seahorse::Client::Plugins::ContentLength::Handler)
        req.handle(step: :send) do |context|
          if scheme != context.http_request.endpoint.scheme
            endpoint = context.http_request.endpoint.dup
            endpoint.scheme = scheme
            endpoint.port = (scheme == 'http' ? 80 : 443)
            context.http_request.endpoint = URI.parse(endpoint.to_s)
          end

          # For more information about authentication in LFS,
          # read https://github.com/github/git-lfs/issues/960
          uri = context.http_request.endpoint
          query = Hash[URI.decode_www_form(uri.query || '')]
          query['token'] = '1'
          uri.query = URI.encode_www_form(query)

          signer = Signers::V4.new(
            context.config.credentials, 's3',
            context.config.region
          )
          url = signer.presigned_url(
            context.http_request,
            expires_in: expires_in,
            body_digest: "UNSIGNED-PAYLOAD"
          )
          Seahorse::Client::Response.new(context: context, data: url)
        end
      end
    end
  end
end
