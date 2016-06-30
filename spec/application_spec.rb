# -*- coding: utf-8 -*-
require 'spec_helper'

describe GitLfsS3::Application do
  EXISTING_OID = '087a4597b239a1ab0e916956f187c7d404b3c3b8aaf3b1fb99027ec1d19cbb59'
  EXISTING_SIZE = '123456'
  MISSING_OID = '0000000000000000000000000000000000000000000000000000000000000000'
  PRESIGNED_URL = 'http://us-west-2.amazonaws.com/bucketname/username/project_guid/oid'
  PROJECT_URL = '/api/projects/10e3eeeb-f55c-4191-8966-17577093642e/lfs'

  before do
    logger = Logger.new('/dev/null')
    GitLfsS3::Application.set :logger, logger
    GitLfsS3::Application.set :s3_bucket, 'test-bucket'
    GitLfsS3::Application.set :aws_region, 'test-region'
    GitLfsS3::Application.set :aws_access_key_id, 'test-key-id'
    GitLfsS3::Application.set :aws_secret_access_key, 'test-key-secret'
    GitLfsS3::Application.set :server_ssl, false
    GitLfsS3::Application.set :server_path, '/:project_guid/lfs'
    GitLfsS3::Application.set :repo_selector, lambda {|req| 'test-repo'}
  end
  
  def bucket_stub
    bucket_class = double("Bucket Class")
    allow(bucket_class).to receive(:new) do
      bucket = double("Bucket Instance")
      allow(bucket).to receive(:object) do
        object = double("Object Instance")
        allow(object).to receive_messages(
          exists?: true,
          size: EXISTING_SIZE,
          presigned_url_with_token: PRESIGNED_URL,
        )
        object
      end
      bucket
    end
    bucket_class
  end

  it 'returns an online message when calling GET on the root' do
    get '/'
    expect(last_response).to be_ok
  end

  it 'returns an S3 url for downloading files' do
    stub_const('Aws::S3::Bucket', bucket_stub)
    url = "/objects/#{EXISTING_OID}"
    get url

    data = JSON.parse(last_response.body)
    expect(last_response.status).to eq(200)
    expect(data['oid']).to eq(EXISTING_OID)
    expect(data['size']).to eq(EXISTING_SIZE)
    expect(data['_links']['self']['href']).to match(/#{url}$/)
    expect(data['_links']['download']['href']).to match(/amazonaws\.com/)
  end

  it 'returns an S3 url for uploading files' do
    stub_const('Aws::S3::Bucket', bucket_stub)
    post '/objects', {oid: MISSING_OID}.to_json

    data = JSON.parse(last_response.body)
    expect(last_response.status).to eq(202)
    expect(data['_links']['upload']['href']).to match(/amazonaws\.com/)
    expect(data['_links']['upload']['header']).not_to be_empty
    expect(data['_links']['verify']['href']).to match(/\/verify/)
  end

  it 'returns an S3 url for an already uplaoded file' do
    stub_const('Aws::S3::Bucket', bucket_stub)
    post '/objects', {oid: EXISTING_OID}.to_json

    data = JSON.parse(last_response.body)
    expect(last_response.status).to eq(202)
    expect(data['_links']['upload']['href']).to match(/amazonaws\.com/)
  end
end

