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

    def object_data(project_guid, oid)
      bucket.object("#{project_guid}/#{oid}")
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
    class Object
      def presigned_url_with_token(http_method, params = {})
        presigner = Aws::S3::Presigner.new(client: client)
        presigner.presigned_url_with_token("#{http_method.downcase}_object", params.merge(
          bucket: bucket_name,
          key: key,
        ))
      end
    end

    class Presigner
      def presigned_url_with_token(method, params = {})
        if params[:key].nil? or params[:key] == ''
          raise ArgumentError, ":key must not be blank"
        end
        virtual_host = !!params.delete(:virtual_host)
        scheme = http_scheme(params, virtual_host)

        req = @client.build_request(method, params)

        use_bucket_as_hostname(req) if virtual_host
        sign_request_with_token(req, expires_in(params), scheme)
        req.send_request.data
      end

private

      def http_scheme(params, virtual_host)
        if params.delete(:secure) == false || virtual_host
          'http'
        else
          @client.config.endpoint.scheme
        end
      end

      def expires_in(params)
        if expires_in = params.delete(:expires_in)
          if expires_in > ONE_WEEK
            msg = "expires_in value of #{expires_in} exceeds one-week maximum"
            raise ArgumentError, msg
          end
          expires_in
        else
          FIFTEEN_MINUTES
        end
      end

      def use_bucket_as_hostname(req)
        req.handlers.remove(Plugins::S3BucketDns::Handler)
        req.handle do |context|
          uri = context.http_request.endpoint
          uri.host = context.params[:bucket]
          uri.path.sub!("/#{context.params[:bucket]}", '')
          uri.scheme = 'http'
          uri.port = 80
          @handler.call(context)
        end
      end

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
