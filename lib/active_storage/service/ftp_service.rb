# frozen_string_literal: true
require "active_storage_ftp/ex_ftp"
require "active_storage_ftp/ex_ftptls"
require "digest/md5"
require "active_support/core_ext/numeric/bytes"

module ActiveStorage

  class Service::FtpService < Service

    def initialize(**config)
      @config = config
    end

    def upload(key, io, checksum: nil, **)
      instrument :upload, key: key, checksum: checksum do
        connection do |ftp|
          path_for(key).tap do |path|
            ftp.mkdir_p(::File.dirname path)
            ftp.chdir(::File.dirname path)
            ftp.storbinary("STOR #{File.basename(key)}", io, Net::FTP::DEFAULT_BLOCKSIZE)
            if ftp_chmod
              ftp.sendcmd("SITE CHMOD #{ftp_chmod.to_s(8)} #{path_for(key)}")
            end
          end
        end
        ensure_integrity_of(key, checksum) if checksum
      end
    end

    def download(key)
      if block_given?
        instrument :streaming_download, key: key do
          URI.open(http_url_for(key)) do |file|
            while data = file.read(64.kilobytes)
              yield data
            end
          end
        end
      else
        instrument :download, key: key do
          URI.open(http_url_for(key)) do |file|
            file.read
          end
        end
      end
    end

    def download_chunk(key, range)
      instrument :download_chunk, key: key, range: range do
        URI.open(http_url_for(key)) do |file|
            file.seek range.begin
            file.read range.size
        end
      end
    end

    def delete(key)
      instrument :delete, key: key do
        begin
          connection do |ftp|
            ftp.chdir(::File.dirname path_for(key))
            ftp.delete(::File.basename path_for(key))
          end
        rescue
          # Ignore files already deleted
        end
      end
    end

    def delete_prefixed(prefix)
      instrument :delete_prefixed, prefix: prefix do
        connection do |ftp|
          ftp.chdir(path_for(prefix))
          ftp.list.each do |file|
            ftp.delete(file.split.last)
          end
        end
      end
    end

    def exist?(key)
      instrument :exist, key: key do |payload|
        response = request_head(key)
        answer = response.code.to_i == 200
        payload[:exist] = answer
        answer
      end
    end

    def url(key, expires_in:, filename:, disposition:, content_type:)
      instrument :url, key: key do |payload|
        generated_url = http_url_for(key)
        payload[:url] = generated_url
        generated_url
      end
    end

    def url_for_direct_upload(key, expires_in:, content_type:, content_length:, checksum:)
      instrument :url, key: key do |payload|
        verified_token_with_expiration = ActiveStorage.verifier.generate(
            {
                key: key,
                content_type: content_type,
                content_length: content_length,
                checksum: checksum
            },
            {expires_in: expires_in,
             purpose: :blob_token}
        )

        generated_url = url_helpers.update_rails_disk_service_url(verified_token_with_expiration, host: current_host)
        payload[:url] = generated_url
        generated_url

      end
    end

    def headers_for_direct_upload(key, content_type:, **)
      {"Content-Type" => content_type}
    end

    def path_for(key) #:nodoc:
      File.join ftp_folder, folder_for(key), key
    end

    private

    attr_reader :config

    def folder_for(key)
      [key[0..1], key[2..3]].join("/")
    end

    def ensure_integrity_of(key, checksum)
      response = request_head(key)
      unless "#{response['Content-MD5']}==" == checksum
        delete key
        raise ActiveStorage::IntegrityError
      end
    end

    def url_helpers
      @url_helpers ||= Rails.application.routes.url_helpers
    end

    def current_host
      ActiveStorage::Current.host
    end

    def request_head(key)
      uri = URI(http_url_for(key))
      request = Net::HTTP.new(uri.host, uri.port)
      request.use_ssl = uri.scheme == 'https'
      request.request_head(uri.path)
    end

    def http_url_for(key)
      ([ftp_url, folder_for(key), key].join('/'))
    end

    def inferred_content_type
      SanitizedFile.new(path).content_type
    end

    def ftp_host
      config.fetch(:ftp_host)
    end

    def ftp_port
      config.fetch(:ftp_port)
    end

    def ftp_user
      config.fetch(:ftp_user)
    end

    def ftp_passwd
      config.fetch(:ftp_passwd)
    end

    def ftp_folder
      config.fetch(:ftp_folder)
    end

    def ftp_url
      config.fetch(:ftp_url)
    end

    def ftp_passive
      config.fetch(:ftp_passive, false)
    end

    def ftp_chmod
      config.fetch(:ftp_chmod, 0600)
    end

    def connection
      ftp = ExFTP.new
      ftp.connect(ftp_host, ftp_port)
      begin
        ftp.passive = ftp_passive
        ftp.login(ftp_user, ftp_passwd)
        yield ftp
      ensure
        ftp.quit
      end
    end

  end
end
