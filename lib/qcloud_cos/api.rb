# encoding: utf-8
require 'qcloud_cos/utils'
require 'qcloud_cos/multipart'
require 'qcloud_cos/model/list'
require 'httparty'
require 'addressable'
require 'xmlsimple'

module QcloudCos
  module Api
    include HTTParty

    # 创建目录
    #
    # @param path [String] 指定要创建的文件夹名字，支持级联创建
    # @param options [Hash] options
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    # @option options [Integer] :biz_attr 指定目录的 biz_attr 由业务端维护, 会在文件信息中返回
    #
    # @return [Hash]
    def create_folder(path, options = {})
      path = fixed_path(path)
      bucket = validates(path, options, :folder_only)

      url = generate_rest_url(bucket, path)

      query = {'op' => 'create'}.merge(Utils.hash_slice(options, 'biz_attr'))

      headers = {
          'Authorization' => authorization.sign(bucket),
          'Content-Type' => 'application/json'
      }

      http.post(url, body: query.to_json, headers: headers).parsed_response
    end

    # 上传文件
    #
    # @param path [String] 指定上传文件的路径
    # @param file_or_bin [File||String] 指定文件或者文件内容
    # @param options [Hash] options
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    # @option options [Integer] :biz_attr 指定文件的 biz_attr 由业务端维护, 会在文件信息中返回
    #
    # @return [Hash]
    def upload(path, file_or_bin, options = {})
      path = fixed_path(path)
      bucket = validates(path, options)

      url = generate_rest_url(bucket, path)

      uri = Addressable::URI.parse(url)

      headers = {
          'Host' => uri.host
      }

      HTTParty.put(url, headers: {
          'User-Agent' => user_agent,
          'x-cos-security-token' => '',
          'x-cos-storage-class' => 'STANDARD',
          'Content-Type' => 'text/txt; charset=utf-8',
          'Authorization' => authorization.sign({}, headers, method: 'put', uri: uri.path)
      }.merge(headers), body: file_or_bin, :debug_output => $stdout)
    end

    alias create upload

    # 分片上传
    #
    # @example
    #
    #   upload_slice('/data/test.log', 'test.log') do |pr|
    #     puts "uploaded #{pr * 100}%"
    #   end
    #
    # @param dst_path [String] 指定文件的目标路径
    # @param src_path [String] 指定文件的本地路径
    # @param block [Block] 指定 Block 来显示进度提示
    # @param options [Hash] options
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    # @option options [Integer] :biz_attr 指定文件的 biz_attr 由业务端维护, 会在文件信息中返回
    # @option options [Integer] :session 指定本次分片上传的 session
    # @option options [Integer] :slice_size 指定分片大小
    #
    # @raise [MissingSessionIdError] 如果缺少 session
    # @raise [FileNotExistError] 如果本地文件不存在
    # @raise [InvalidFilePathError] 如果目标路径是非法文件路径
    #
    # @return [Hash]
    def upload_slice(dst_path, src_path, options = {}, &block)
      dst_path = fixed_path(dst_path)
      fail FileNotExistError unless File.exist?(src_path)
      bucket = validates(dst_path, options)

      multipart = QcloudCos::Multipart.new(
          dst_path,
          src_path,
          options.merge(bucket: bucket, authorization: authorization)
      )
      multipart.upload(&block)
      multipart.result
    end

    # 初始化分片上传
    #
    # @param path [String] 指定上传文件的路径
    # @param filesize [Integer] 指定文件总大小
    # @param sha [String] 指定该文件的 sha 值
    # @param options [Hash] options
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    # @option options [Integer] :biz_attr 指定文件的 biz_attr 由业务端维护, 会在文件信息中返回
    # @option options [Integer] :session 如果想要断点续传,则带上上一次的session
    # @option options [Integer] :slice_size 指定分片大小
    #
    # @return [Hash]
    def init_slice_upload(path, filesize, sha, options = {})
      path = fixed_path(path)
      bucket = validates(path, options)

      url = generate_rest_url(bucket, path)
      query = generate_slice_upload_query(filesize, sha, options)
      sign = options['sign'] || authorization.sign(bucket)

      http.post(url, query: query, headers: {'Authorization' => sign}).parsed_response
    end

    # 上传分片数据
    #
    # @param path [String] 指定上传文件的路径
    # @param session [String] 指定分片上传的 session id
    # @param offset [Integer] 本次分片位移
    # @param content [Binary] 指定文件内容
    # @param options [Hash] options
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    #
    # @return [Hash]
    def upload_part(path, session, offset, content, options = {})
      path = fixed_path(path)
      bucket = validates(path, options)

      url = generate_rest_url(bucket, path)
      query = generate_upload_part_query(session, offset, content)
      sign = options['sign'] || authorization.sign(bucket)

      http.post(url, query: query, headers: {'Authorization' => sign}).parsed_response
    end

    # 更新文件或者目录信息
    #
    # @param path [String] 指定文件或者目录路径
    # @param biz_attr [String] 指定文件或者目录的 biz_attr
    # @param options [Hash] 额外参数
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    #
    # @return [Hash]
    def update(path, biz_attr, options = {})
      path = fixed_path(path)
      bucket = validates(path, options, 'both')
      url = generate_rest_url(bucket, path)

      query = {'op' => 'update', 'biz_attr' => biz_attr}

      resource = "/#{bucket}#{Utils.url_encode(path)}"
      headers = {
          'Authorization' => authorization.sign_once(bucket, resource),
          'Content-Type' => 'application/json'
      }

      http.post(url, body: query.to_json, headers: headers).parsed_response
    end

    # 删除文件或者目录
    #
    # @param path [String] 指定文件或者目录路径
    # @param options [Hash] 额外参数
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    #
    # @return [Hash]
    def delete(path, options = {})
      path = fixed_path(path)
      bucket = validates(path, options, 'both')
      url = generate_rest_url(bucket, path)

      query = {'op' => 'delete'}

      resource = "/#{bucket}#{Utils.url_encode(path)}"
      headers = {
          'Authorization' => authorization.sign_once(bucket, resource),
          'Content-Type' => 'application/json'
      }

      http.post(url, body: query.to_json, headers: headers).parsed_response
    end

    # 删除目录
    #
    # @param path [String] 指定目录路径
    # @param options [Hash] 额外参数
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    # @option options [Boolean] :recursive (false) 指定是否需要级连删除
    #
    # @raise [InvalidFolderPathError] 如果路径是非法文件夹路径
    #
    # @return [Hash]
    def delete_folder(path, options = {})
      validates(path, options, 'folder_only')

      return delete(path, options) if options['recursive'] != true

      all(path, options).each do |object|
        if object.is_a?(QcloudCos::FolderObject)
          delete_folder("#{path}#{object.name}/", options)
        elsif object.is_a?(QcloudCos::FileObject)
          delete_file("#{path}#{object.name}", options)
        end
      end
      delete(path)
    end

    # 删除文件
    #
    # @param path [String] 指定文件路径
    # @param options [Hash] 额外参数
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    #
    # @raise [InvalidFilePathError] 如果文件路径不合法
    #
    # @return [Hash]
    def delete_file(path, options = {})
      fail InvalidFilePathError if path.end_with?('/')
      delete(path, options)
    end

    # 查看文件或者文件夹信息
    #
    # @param path [String] 指定文件或者文件夹目录
    # @param options [Hash] 额外参数
    # @option options [String] :bucket (config.bucket_name) 指定当前 bucket, 默认是配置里面的 bucket
    #
    # @return [Hash]
    def stat(path, options = {})
      path = fixed_path(path)
      bucket = validates(path, options, 'both')
      url = generate_rest_url(bucket, path)

      query = {'op' => 'stat'}
      sign = authorization.sign(bucket)

      http.get(url, query: query, headers: {'Authorization' => sign}).parsed_response
    end

    private

    def generate_slice_upload_query(filesize, sha, options)
      {
          'op' => 'upload_slice',
          'filesize' => filesize,
          'sha' => sha,
          'filecontent' => Tempfile.new("temp-#{Time.now.to_i}")
      }.merge(Utils.hash_slice(options, 'biz_attr', 'session', 'slice_size'))
    end

    def generate_upload_part_query(session, offset, content)
      {
          'op' => 'upload_slice',
          'session' => session,
          'offset' => offset
      }.merge(generate_file_query(content))
    end

    def generate_file_query(file_or_bin)
      query = {}
      if file_or_bin.respond_to?(:read)
        query['filecontent'] = file_or_bin
        query['sha'] = Utils.generate_sha(IO.binread(file_or_bin))
      else
        query['filecontent'] = generate_tempfile(file_or_bin)
        query['sha'] = Utils.generate_sha(file_or_bin)
      end
      query
    end

    def generate_tempfile(file_or_bin)
      tempfile = Tempfile.new("temp-#{Time.now.to_i}")
      tempfile.write(file_or_bin)
      tempfile.rewind
      tempfile
    end


    def user_agent
      "qcloud-cos-sdk-ruby/#{QcloudCos::VERSION} (#{RbConfig::CONFIG['host_os']} ruby-#{RbConfig::CONFIG['ruby_version']})"
    end

  end
end
