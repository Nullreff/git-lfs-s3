require 'base64'
require 'openssl'
require 'time'

module GitLfsS3
  class Application < Sinatra::Application
    include AwsHelpers

    configure do
      disable :sessions
      enable :logging
    end

    helpers do
      def logger
        settings.logger
      end

      def digest
        OpenSSL::Digest.new('sha256')
      end

      def project
        GitLfsS3::Application.settings.project_selector(request)
      end

      def expiriation
        GitLfsS3::Application.settings.token_expiration || (60 * 15) # Fifteen minutes
      end

      def secret
        GitLfsS3::Application.settings.token_secret
      end

      def verbose_errors?
        GitLfsS3::Application.settings.verbose_errors || false
      end

      def verify_link 
        protocol = GitLfsS3::Application.settings.server_ssl ? 'https' : 'http'
        server_path = GitLfsS3::Application.settings.server_path.gsub(':project', project)
        host = request.host_with_port
        "#{protocol}://#{host}#{File.join(server_path, 'verify')}?token=1"
      end

      def verify_header
        expires = (Time.now.utc + expriation).iso8601
        message = {project: project, expires: expires}
        message[:verify] = OpenSSL::HMAC.hexdigest(digest, secret, message.to_json)
        token = Base64.strict_encode64(MultiJson.dump(message))
        {Authorization: "RemoteAuth #{token}"}
      end
    end

    def check_authorizization
      header = request.env['HTTP_AUTHORIZATION']
      return false, "Missing auth header" unless header

      token = header[/^RemoteAuth (.+)$/, 1]
      return false, "Missing auth token" unless token

      message = MultiJson.load(Base64.decode64(token)) rescue nil
      return false, "Error decoding auth token" unless message

      expires = DateTime.parse(message['expires']) rescue nil
      return false, "No auth token expriation" unless message

      found_sig = message.delete('verify')
      expected_sig = OpenSSL::HMAC.hexdigest(digest, secret, message.to_json)

      return false, "Mismatching signatures\nReceived: '#{found_sig}'\nExpected: '#{expected_sig}'" unless found_sig == expected_sig
      return false, "Mismatching projects" unless message['project'] == project
      return false, "Auth token has expired" unless expires > Time.now.utc

      return true
    end

    def protected!
      result, message = check_authorizization
      unless result
        response['WWW-Authenticate'] = %(RemoteAuth realm="Restricted Area")
        throw(:halt, [401, verbose_errors? ? message : 'Invalid auth token'])
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
              {actions: {upload: {href: object.presigned_url_with_token(:put)},
                         verify: {href: verify_link, header: verify_header}}}
            when 'download'
              {
                error: {code: 404, message: 'Object does not exist on the server'}}
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
            'href' => object.presigned_url_with_token(:get)
          }
        }
      }

      body MultiJson.dump(resp)
    end

    post "/objects", provides: 'application/vnd.git-lfs+json' do
      data = MultiJson.load request.body.tap { |d| d.rewind }.read
      object = object_data(project, data['oid'])

      links = if object.exists? && object.size == data['size']
        status 200
        {download: {href: object.presigned_url_with_token(:get)}}
      else
        status 202
        {upload: {href: object.presigned_url_with_token(:put)},
         verify: {href: verify_link, header: verify_header}}
      end

      body MultiJson.dump({_links: links})
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
