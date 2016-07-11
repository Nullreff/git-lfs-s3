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

      def project
        GitLfsS3::Application.settings.project_selector(request)
      end

      def verify_link 
        protocol = GitLfsS3::Application.settings.server_ssl ? 'https' : 'http'
        server_path = GitLfsS3::Application.settings.server_path.gsub(':project', project)
        host = request.host_with_port
        "#{protocol}://#{host}#{File.join(server_path, 'verify?token=1')}"
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

    # Git LFS v1 Batch API
    # https://github.com/github/git-lfs/blob/master/docs/api/v1/http-v1-batch.md
    VALID_OPERATIONS = %w(upload download)
    post '/objects/batch', provides: 'application/vnd.git-lfs+json' do
      data = MultiJson.load(request.body.tap { |b| b.rewind }.read)

      operation = data['operation']
      results = (data['objects'] || []).map do |obj|
        object = object_data(project, obj['oid'])
        base = {
          oid: obj['oid'],
          size: obj['size'],
        }

        base.merge(
          if object.exists? && VALID_OPERATIONS.include?(operation)
            {actions: {download: {href: object.presigned_url_with_token(:get)}}}
          else
            case operation
            when 'upload'
              {actions: {upload: {href: object.presigned_url_with_token(:put)}, verify: {href: verify_link}}}
            when 'download'
              {error: {code: 404, message: 'Object does not exist on the server'}}
            else
              {error: {code: 400, message: "Invalid operation '#{operation}'"}}
            end
          end
        )
      end

      body MultiJson.dump({objects: results})
    end

    # Git LFS v1 Legacy API
    # https://github.com/github/git-lfs/blob/master/docs/api/v1/http-v1-legacy.md
    get "/objects/:oid", provides: 'application/vnd.git-lfs+json' do
      object = object_data(project, params[:oid])

      unless object.exists?
        status 404
        return body MultiJson.dump({message: 'Object not found'})
      end

      status 200
      resp = {
        'oid' => params[:oid],
        'size' => object.size,
        '_links' => {
          'self' => {
            'href' => request.url
          },
          'download' => {
            # TODO: cloudfront support
            'href' => object_data(project, params[:oid]).presigned_url_with_token(:get)
          }
        }
      }

      body MultiJson.dump(resp)
    end

    post "/objects", provides: 'application/vnd.git-lfs+json' do
      logger.debug headers.inspect
      service = UploadService.service_for(project, request)
      logger.debug service.response

      status service.status
      body MultiJson.dump(service.response)
    end

    post '/verify', provides: 'application/vnd.git-lfs+json' do
      data = MultiJson.load(request.body.tap { |b| b.rewind }.read)
      object = object_data(project, data['oid'])

      if object.exists? && object.size == data['size']
        status 200
      else
        status 404
      end
    end
  end
end
