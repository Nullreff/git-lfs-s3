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
      object_link = object_data(project_guid, params[:oid]).presigned_url(:get).to_s

      uri = URI.parse(object_link)
      query = Hash[URI.decode_www_form(uri.query)]
      authorization = "#{query['X-Amz-Algorithm']} Credential=#{query['X-Amz-Credential']}, SignedHeaders=#{query['X-Amz-SignedHeaders']}, Signature=#{query['X-Amz-Signature']}"
      expires = query['X-Amz-Expires']

      %w(Algorithm Credential SignedHeaders Signature Expires).each do |header|
        query.delete("X-Amz-#{header}")
      end
      uri.query = URI.encode_www_form(query)

      if object.exists?
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
              # https://github.com/github/git-lfs/issues/960 
              'headers': {
                'Authorization': authorization,
              },
              'expires': expires,
            }
          }
        }

        body MultiJson.dump(resp)
      else
        status 404
        body MultiJson.dump({message: 'Object not found'})
      end
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
