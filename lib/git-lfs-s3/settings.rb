module GitLfsS3
  module Settings
    def digest
      OpenSSL::Digest.new('sha256')
    end

    def project
      GitLfsS3::Application.settings.project_selector(request)
    end

    def expiration
      GitLfsS3::Application.settings.token_expiration
    end

    def secret
      GitLfsS3::Application.settings.token_secret or
        raise 'You must configure an application secret for generating secure tokens'
    end

    def verbose_errors?
      GitLfsS3::Application.settings.verbose_errors
    end

    def protocol
      GitLfsS3::Application.settings.server_ssl ? 'https' : 'http'
    end

    def server_path
        GitLfsS3::Application.settings.server_path.gsub(':project', project)
    end
  end
end
