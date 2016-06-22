require 'digest/sha2'

module GitLfsS3
  class Application < Sinatra::Application
    include AwsHelpers

    class << self
      attr_reader :auth_callback

      def on_authenticate(&block)
        @auth_callback = block
      end

      def authentication_enabled?
        !auth_callback.nil?
      end

      def perform_authentication(username, password)
        auth_callback.call(username, password)
      end
    end

    configure do
      disable :sessions
      enable :logging
    end

    helpers do
      def logger
        settings.logger
      end

      def hmac(key, data, hex = false)
        digest = OpenSSL::Digest.new('sha256')
        if hex
          OpenSSL::HMAC.hexdigest(digest, key, data)
        else
          OpenSSL::HMAC.digest(digest, key, data)
        end
      end
    end

    def authorized?
      true
      # @auth ||=  Rack::Auth::Basic::Request.new(request.env)
      # @auth.provided? && @auth.basic? && @auth.credentials && self.class.auth_callback.call(
      #   @auth.credentials[0], @auth.credentials[1]
      # )
    end

    def protected!
      unless authorized?
        response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
        throw(:halt, [401, "Invalid username or password"])
      end
    end

    before { protected! }

    get '/' do
      "Git LFS S3 is online."
    end

    get "/objects/:oid", provides: 'application/vnd.git-lfs+json' do
      project_guid = request.env["REQUEST_URI"][/projects\/(\S*)\/lfs/,1]
      object = object_data(project_guid, params[:oid])

      unless object.exists?
        status 404
        return body MultiJson.dump({message: 'Object not found'})
      end

      # For more information about authentication in LFS,
      # read https://github.com/github/git-lfs/issues/960 

      object_link = object_data(project_guid, params[:oid]).public_url
      uri = URI.parse(object_link)
      now = Time.now.utc
      now_datetime = now.strftime('%Y%m%dT%H%M%SZ')
      now_date = now.strftime('%Y%m%d')
      method = 'GET'
      expires = (5 * 60).to_s # 5 min
      payload_hash = (Digest::SHA2.new << '').to_s
      algorithm = 'AWS4-HMAC-SHA256'
      service = 's3'
      cred_scope = "#{now_date}/#{aws_region}/#{service}/aws4_request"
      credential = aws_access_key_id + '/' + cred_scope

      headers = {
        'Host' => uri.host,
      }
      signed_headers = headers.keys.map(&:downcase).join(';')
      header_list = headers.map{|k,v| "#{k.downcase}:#{v.downcase.strip.gsub(/  /, ' ')}"}.sort.join("\n")

      query = {
        'X-Amz-Algorithm' => algorithm,
        'X-Amz-Credential' => credential,
        'X-Amz-Date' => now_datetime,
        'X-Amz-Expires' => expires,
        'X-Amz-SignedHeaders' => signed_headers,
      }
      uri.query = URI.encode_www_form(query.sort_by{|k,v| k})

      # Step 1: Construct Canonical Request
      canonical_request = [method, uri.path, uri.query, header_list + "\n", signed_headers, payload_hash].join("\n")
      logger.debug "Canonical Request: \n#{canonical_request}"

      # Step 2: String to Sign
      request_hash = (Digest::SHA2.new << canonical_request).to_s
      string_to_sign = [algorithm, now_datetime, cred_scope, request_hash].join("\n")
      logger.debug "String To Sign: \n#{string_to_sign}"

      # Step 3: Calculate Signature
      signing_key = hmac(hmac(hmac(hmac('AWS4' + aws_secret_access_key, now_date), aws_region), service), 'aws4_request')
      signature = hmac(signing_key, string_to_sign, true)
      logger.debug "Signature: \n#{signature}"

      # Step 4: Add Signature to Request
      query['X-Amz-Signature'] = signature
      uri.query = URI.encode_www_form(query.sort_by{|k,v| k})

      status 200
      resp = {
        'oid' => params[:oid],
        'size' => object.size,
        '_links' => {
          'self' => {
            'href' => File.join(settings.server_url, 'objects', params[:oid])
          },
          'download' => {
            # TODO: cloudfront support
            'href' => uri.to_s,
          }
        }
      }
      logger.debug "Response: \n#{JSON.pretty_generate(resp)}"

      body MultiJson.dump(resp)
    end

    post "/objects", provides: 'application/vnd.git-lfs+json' do
      # "REQUEST_URI"=>"/api/projects/10e3eeeb-f55c-4191-8966-17577093642e/lfs/objects"
      project_guid = request.env["REQUEST_URI"][/projects\/(\S*)\/lfs/,1]

      logger.debug headers.inspect
      service = UploadService.service_for(project_guid, request.body)
      logger.debug service.response

      status service.status
      body MultiJson.dump(service.response)
    end

    post '/verify', provides: 'application/vnd.git-lfs+json' do
      project_guid = request.env["REQUEST_URI"][/projects\/(\S*)\/lfs/,1]
      data = MultiJson.load(request.body.tap { |b| b.rewind }.read)
      object = object_data(project_guid, data['oid'])

      if object.exists? && object.size == data['size']
        status 200
      else
        status 404
      end
    end
  end
end
