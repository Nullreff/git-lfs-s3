require "git-lfs-s3/services/upload/base"
require "git-lfs-s3/services/upload/object_exists"
require "git-lfs-s3/services/upload/upload_required"

module GitLfsS3
  module UploadService
    extend self
    extend AwsHelpers

    MODULES = [
      ObjectExists,
      UploadRequired
    ]

    def service_for(project_guid, request)
      req = MultiJson.load request.body.tap { |d| d.rewind }.read
      object = object_data(project_guid, req['oid'])
      host = request.host_with_port

      MODULES.each do |mod|
        return mod.new(req, object, project_guid, host) if mod.should_handle?(req, object)
      end

      nil
    end
  end
end
