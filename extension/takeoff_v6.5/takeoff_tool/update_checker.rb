module TakeoffTool
  module UpdateChecker

    VERSION_URL = "https://form-field.com/version.json".freeze
    CURRENT_VERSION = "11.0.0".freeze  # bump this with each release

    @checked_this_session = false

    def self.check_for_update
      return if @checked_this_session
      @checked_this_session = true

      puts "[FF Update] Checking for updates..."

      begin
        require 'net/http'
        require 'uri'
        require 'json'

        uri = URI.parse(VERSION_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        response = http.request(Net::HTTP::Get.new(uri.path))

        if response.code != "200"
          puts "[FF Update] HTTP #{response.code}"
          return
        end

        data = JSON.parse(response.body)
        remote_version = data["version"]
        download_url   = data["download"]
        notes          = data["notes"]

        puts "[FF Update] Current: #{CURRENT_VERSION} → Remote: #{remote_version}"

        if remote_version && newer?(remote_version, CURRENT_VERSION)
          show_update_notification(remote_version, download_url, notes)
        else
          puts "[FF Update] Up to date."
        end

      rescue => e
        puts "[FF Update] Error: #{e.message}"
      end
    end

    private

    def self.newer?(remote, current)
      r = remote.split('.').map(&:to_i)
      c = current.split('.').map(&:to_i)
      max = [r.length, c.length].max
      r += [0] * (max - r.length)
      c += [0] * (max - c.length)
      r.each_with_index do |rv, i|
        return true if rv > c[i]
        return false if rv < c[i]
      end
      false
    end

    def self.show_update_notification(version, url, notes)
      result = UI.messagebox(
        "Form and Field v#{version} is available.\n\n#{notes}\n\nDownload the update?",
        MB_YESNO
      )
      UI.openURL(url) if result == IDYES
    end

  end
end
