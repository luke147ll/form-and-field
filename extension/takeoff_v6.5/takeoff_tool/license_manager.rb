require 'set'

module TakeoffTool
  module LicenseManager

    # ── LemonSqueezy API endpoints ──
    LS_VALIDATE_URL   = "https://api.lemonsqueezy.com/v1/licenses/validate".freeze unless defined?(LS_VALIDATE_URL)
    LS_ACTIVATE_URL   = "https://api.lemonsqueezy.com/v1/licenses/activate".freeze   unless defined?(LS_ACTIVATE_URL)
    LS_DEACTIVATE_URL = "https://api.lemonsqueezy.com/v1/licenses/deactivate".freeze unless defined?(LS_DEACTIVATE_URL)

    CACHE_DURATION = 86_400   unless defined?(CACHE_DURATION)   # 24 hours
    GRACE_PERIOD   = 259_200  unless defined?(GRACE_PERIOD)     # 72 hours offline grace

    DEFAULTS_SECTION = "TakeoffTool_License".freeze unless defined?(DEFAULTS_SECTION)

    EVENT_LICENSE_CHANGED = :license_changed unless defined?(EVENT_LICENSE_CHANGED)

    # ── Beta Keys ──
    # Local-only keys that bypass LemonSqueezy API.
    # Expire automatically after BETA_EXPIRY.
    BETA_KEYS = Set.new(%w[
      timber-alpha
      rafter-bravo
      truss-charlie
      joist-delta
      purlin-echo
      beam-foxtrot
      stud-golf
      slab-hotel
      ridge-india
      chord-juliet
    ]).freeze unless defined?(BETA_KEYS)

    BETA_EXPIRY = Time.new(2026, 6, 30, 23, 59, 59).freeze unless defined?(BETA_EXPIRY)

    # Dev bypass — set from Ruby Console:
    #   TakeoffTool::LicenseManager.dev_mode = true
    @dev_mode = false
    class << self; attr_accessor :dev_mode; end

    # ── Public API ──────────────────────────────────────────────

    # Returns true if the user has a valid, active license.
    def self.licensed?
      return true if @dev_mode

      key = stored_key
      return false unless key && !key.empty?

      # Beta keys — validate locally, no API
      return beta_valid?(key) if beta_key?(key)

      # 1. Check fresh cache
      if cache_valid?
        cached = Sketchup.read_default(DEFAULTS_SECTION, "cached_status")
        return cached == "active"
      end

      # 2. Cache stale — try live validation
      result = validate(key)
      return true if result[:valid]

      # 3. Network failed or invalid — check grace period
      return true if within_grace_period?

      false
    end

    # Returns a status hash for UI display.
    def self.status
      key = stored_key
      unless key && !key.empty?
        return { valid: false, status: "inactive", trial: false, expiry: nil }
      end

      # Beta key status — no cache, local only
      if beta_key?(key)
        valid = beta_valid?(key)
        return {
          valid: valid,
          status: valid ? "active" : "expired",
          trial: false,
          beta: true,
          expiry: BETA_EXPIRY.strftime("%Y-%m-%d"),
          last_validated: Time.now.strftime("%Y-%m-%d %H:%M"),
          key_tail: key.length >= 8 ? key[-8..] : key
        }
      end

      cached_status = Sketchup.read_default(DEFAULTS_SECTION, "cached_status") || "unknown"
      cached_expiry = Sketchup.read_default(DEFAULTS_SECTION, "cached_expiry")
      last_valid    = Sketchup.read_default(DEFAULTS_SECTION, "last_valid_at").to_i

      valid = (cached_status == "active")
      # If cache is stale but within grace, still show as active (offline)
      if !valid && within_grace_period?
        valid = true
        cached_status = "active"
      end

      {
        valid: valid,
        status: cached_status,
        trial: false,
        expiry: cached_expiry,
        last_validated: last_valid > 0 ? Time.at(last_valid).strftime("%Y-%m-%d %H:%M") : nil,
        key_tail: key.length >= 8 ? key[-8..] : key
      }
    end

    # Activate a license key on this machine.
    def self.activate(license_key)
      return { success: false, error: "No license key provided" } if license_key.nil? || license_key.strip.empty?
      license_key = license_key.strip

      # Beta key — activate locally, no API call
      if beta_key?(license_key)
        unless beta_valid?(license_key)
          return { success: false, error: "Beta key expired (#{BETA_EXPIRY.strftime('%Y-%m-%d')})" }
        end
        Sketchup.write_default(DEFAULTS_SECTION, "license_key", license_key)
        Sketchup.write_default(DEFAULTS_SECTION, "instance_id", "beta-local")
        cache_validation("active")
        TakeoffTool.publish(EVENT_LICENSE_CHANGED, valid: true, status: "active") rescue nil
        return { success: true, error: nil }
      end

      body = { license_key: license_key, instance_name: machine_id }
      resp = ls_request(LS_ACTIVATE_URL, body)

      if resp[:error]
        return { success: false, error: resp[:error] }
      end

      if resp["activated"] || resp["valid"]
        instance_id = resp.dig("instance", "id") || resp.dig("instance_id")
        Sketchup.write_default(DEFAULTS_SECTION, "license_key", license_key)
        Sketchup.write_default(DEFAULTS_SECTION, "instance_id", instance_id.to_s) if instance_id

        # Cache the validation
        ls_status = resp.dig("license_key", "status") || "active"
        cache_validation(ls_status, resp)

        TakeoffTool.publish(EVENT_LICENSE_CHANGED, valid: true, status: "active") rescue nil
        { success: true, error: nil }
      else
        error_msg = resp["error"] || resp.dig("license_key", "status") || "Activation failed"
        { success: false, error: error_msg }
      end
    end

    # Validate the stored (or provided) license key.
    def self.validate(license_key = nil)
      key = license_key || stored_key
      return { valid: false, status: "inactive", meta: {} } unless key && !key.empty?

      # Beta key — validate locally, no API call
      if beta_key?(key)
        valid = beta_valid?(key)
        return { valid: valid, status: valid ? "active" : "expired", meta: { beta: true } }
      end

      body = { license_key: key }
      inst = stored_instance_id
      body[:instance_id] = inst if inst && !inst.empty?

      resp = ls_request(LS_VALIDATE_URL, body)

      if resp[:error]
        return { valid: false, status: "error", meta: { error: resp[:error] } }
      end

      valid = resp["valid"] == true
      ls_status = resp.dig("license_key", "status") || (valid ? "active" : "invalid")
      cache_validation(ls_status, resp) if valid

      { valid: valid, status: ls_status, meta: resp["meta"] || {} }
    end

    # Deactivate this machine's license.
    def self.deactivate
      key = stored_key
      inst = stored_instance_id
      return { success: false } unless key && !key.empty?

      if inst && !inst.empty? && !beta_key?(key)
        body = { license_key: key, instance_id: inst }
        ls_request(LS_DEACTIVATE_URL, body)  # best-effort
      end

      # Clear all stored data
      Sketchup.write_default(DEFAULTS_SECTION, "license_key", "")
      Sketchup.write_default(DEFAULTS_SECTION, "instance_id", "")
      Sketchup.write_default(DEFAULTS_SECTION, "cached_status", "")
      Sketchup.write_default(DEFAULTS_SECTION, "cached_at", "")
      Sketchup.write_default(DEFAULTS_SECTION, "cached_expiry", "")
      Sketchup.write_default(DEFAULTS_SECTION, "last_valid_at", "")

      TakeoffTool.publish(EVENT_LICENSE_CHANGED, valid: false, status: "inactive") rescue nil
      { success: true }
    end

    # ── Activation Dialog ───────────────────────────────────────

    def self.show_activation_dialog
      if @activate_dialog && @activate_dialog.visible?
        @activate_dialog.bring_to_front
        return
      end

      @activate_dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field \u2014 Activate License",
        preferences_key: "FF_LicenseActivate",
        width: 420, height: 300,
        left: 300, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @activate_dialog.set_html(activation_html)

      @activate_dialog.add_action_callback('activate_license') do |_ctx, key_str|
        result = activate(key_str)
        if result[:success]
          js = "showResult(true, 'License activated successfully!');"
          @activate_dialog.execute_script(js)
          # Close after a short delay
          UI.start_timer(1.5, false) do
            @activate_dialog.close if @activate_dialog
          end
        else
          err = (result[:error] || "Activation failed").gsub("'", "\\\\'")
          @activate_dialog.execute_script("showResult(false, '#{err}');")
        end
      end

      @activate_dialog.add_action_callback('open_store') do |_ctx|
        UI.openURL("https://formandfield.lemonsqueezy.com")
      end

      @activate_dialog.add_action_callback('check_status') do |_ctx|
        s = status
        require 'json'
        @activate_dialog.execute_script("receiveStatus(#{JSON.generate(s)});")
      end

      @activate_dialog.show
    end

    # ── Status Dialog ───────────────────────────────────────────

    def self.show_status_dialog
      if @status_dialog && @status_dialog.visible?
        @status_dialog.bring_to_front
        return
      end

      @status_dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field \u2014 License",
        preferences_key: "FF_LicenseStatus",
        width: 420, height: 340,
        left: 300, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @status_dialog.set_html(status_html)

      @status_dialog.add_action_callback('check_status') do |_ctx|
        s = status
        require 'json'
        @status_dialog.execute_script("receiveStatus(#{JSON.generate(s)});")
      end

      @status_dialog.add_action_callback('deactivate_license') do |_ctx|
        result = deactivate
        if result[:success]
          @status_dialog.execute_script("receiveStatus({valid:false,status:'inactive',key_tail:''});")
          @status_dialog.execute_script("showMsg('License deactivated from this machine.');")
        end
      end

      @status_dialog.add_action_callback('revalidate') do |_ctx|
        result = validate
        s = status
        require 'json'
        @status_dialog.execute_script("receiveStatus(#{JSON.generate(s)});")
        if result[:valid]
          @status_dialog.execute_script("showMsg('Validation successful.');")
        else
          err = (result[:meta]&.dig(:error) || result[:status] || "Validation failed").to_s.gsub("'", "\\\\'")
          @status_dialog.execute_script("showMsg('#{err}');")
        end
      end

      @status_dialog.add_action_callback('manage_subscription') do |_ctx|
        UI.openURL("https://formandfield.lemonsqueezy.com/billing")
      end

      @status_dialog.add_action_callback('open_store') do |_ctx|
        UI.openURL("https://formandfield.lemonsqueezy.com")
      end

      @status_dialog.show
    end

    # ── Private Helpers ─────────────────────────────────────────

    private

    def self.beta_key?(key)
      BETA_KEYS.include?(key.to_s)
    end

    def self.beta_valid?(key)
      beta_key?(key) && Time.now < BETA_EXPIRY
    end

    def self.machine_id
      @_machine_id ||= begin
        require 'digest'
        parts = []
        parts << (Socket.gethostname rescue ENV['COMPUTERNAME'] || ENV['HOSTNAME'] || 'unknown')
        # Use username as additional differentiator
        parts << (ENV['USERNAME'] || ENV['USER'] || 'user')
        # SketchUp serial if available
        parts << (Sketchup.app_name rescue 'SketchUp')
        Digest::SHA256.hexdigest(parts.join('|'))[0, 16]
      end
    end

    def self.stored_key
      val = Sketchup.read_default(DEFAULTS_SECTION, "license_key")
      (val && !val.to_s.empty?) ? val.to_s : nil
    end

    def self.stored_instance_id
      val = Sketchup.read_default(DEFAULTS_SECTION, "instance_id")
      (val && !val.to_s.empty?) ? val.to_s : nil
    end

    def self.cache_valid?
      ts = Sketchup.read_default(DEFAULTS_SECTION, "cached_at").to_i
      ts > 0 && (Time.now.to_i - ts) < CACHE_DURATION
    end

    def self.within_grace_period?
      ts = Sketchup.read_default(DEFAULTS_SECTION, "last_valid_at").to_i
      ts > 0 && (Time.now.to_i - ts) < GRACE_PERIOD
    end

    def self.cache_validation(status_str, resp = {})
      Sketchup.write_default(DEFAULTS_SECTION, "cached_status", status_str)
      Sketchup.write_default(DEFAULTS_SECTION, "cached_at", Time.now.to_i.to_s)
      Sketchup.write_default(DEFAULTS_SECTION, "last_valid_at", Time.now.to_i.to_s)
      expiry = resp.dig("license_key", "expires_at")
      Sketchup.write_default(DEFAULTS_SECTION, "cached_expiry", expiry.to_s) if expiry
    end

    def self.ls_request(url, body)
      require 'net/http'
      require 'uri'
      require 'json'

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 10

      # SketchUp's Ruby may have SSL cert issues on some systems.
      # Try VERIFY_PEER first; fall back to VERIFY_NONE if needed.
      begin
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      rescue
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = JSON.generate(body)

      response = http.request(request)
      JSON.parse(response.body)
    rescue => e
      puts "[FF LicenseManager] HTTP error: #{e.class} — #{e.message}"
      { error: e.message }
    end

    # ── HTML Templates ──────────────────────────────────────────

    def self.activation_html
      <<~HTML
      <!DOCTYPE html>
      <html><head><meta charset="utf-8">
      <style>
        :root{
          --base:#1e1e2e;--mantle:#181825;--crust:#11111b;
          --surface0:#313244;--surface1:#45475a;--surface2:#585b70;
          --overlay0:#6c7086;--text:#cdd6f4;--subtext0:#a6adc8;
          --green:#a6e3a1;--red:#f38ba8;--mauve:#cba6f7;--peach:#fab387;
          --font-mono:'JetBrains Mono','Fira Code','Consolas',monospace;
        }
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.5 var(--font-mono);background:var(--base);color:var(--text);
          display:flex;flex-direction:column;height:100vh;overflow:hidden}
        .header{background:var(--crust);border-bottom:1px solid var(--surface0);
          padding:14px 20px;text-align:center}
        .header h1{font-size:13px;font-weight:700;color:var(--mauve);letter-spacing:.5px}
        .header p{font-size:10px;color:var(--overlay0);margin-top:2px}
        .body{flex:1;padding:20px;display:flex;flex-direction:column;gap:14px}
        label{font-size:10px;color:var(--subtext0);font-weight:600;letter-spacing:.5px}
        input{width:100%;padding:10px 12px;border-radius:6px;border:1px solid var(--surface1);
          background:var(--mantle);color:var(--text);font:12px var(--font-mono);
          outline:none;transition:border-color .15s}
        input:focus{border-color:var(--mauve)}
        input::placeholder{color:var(--surface2)}
        .btn{width:100%;padding:10px;border-radius:6px;border:none;font:600 12px var(--font-mono);
          cursor:pointer;transition:all .15s;letter-spacing:.5px}
        .btn-activate{background:var(--green);color:var(--crust)}
        .btn-activate:hover{filter:brightness(1.1)}
        .btn-activate:disabled{opacity:.5;cursor:default}
        .msg{min-height:32px;display:flex;align-items:center;justify-content:center;
          font-size:11px;border-radius:4px;padding:6px 10px}
        .msg.ok{background:rgba(166,227,161,.1);color:var(--green)}
        .msg.err{background:rgba(243,139,168,.1);color:var(--red)}
        .footer{padding:10px 20px;text-align:center;border-top:1px solid var(--surface0)}
        .footer a{font-size:10px;color:var(--mauve);cursor:pointer;text-decoration:none}
        .footer a:hover{text-decoration:underline}
      </style>
      </head><body>
        <div class="header">
          <h1>FORM AND FIELD</h1>
          <p>Enter your license key to activate</p>
        </div>
        <div class="body">
          <div>
            <label>LICENSE KEY</label>
            <input id="keyInput" type="text" placeholder="XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
              spellcheck="false" autocomplete="off">
          </div>
          <button class="btn btn-activate" id="activateBtn" onclick="doActivate()">Activate</button>
          <div class="msg" id="msg"></div>
        </div>
        <div class="footer">
          <a onclick="sketchup.open_store()">Don't have a license? Get one here</a>
        </div>
        <script>
          function doActivate(){
            var key=document.getElementById('keyInput').value.trim();
            if(!key){showResult(false,'Please enter a license key.');return;}
            document.getElementById('activateBtn').disabled=true;
            document.getElementById('activateBtn').textContent='Activating...';
            document.getElementById('msg').className='msg';
            document.getElementById('msg').textContent='';
            sketchup.activate_license(key);
          }
          function showResult(ok,text){
            var el=document.getElementById('msg');
            el.className='msg '+(ok?'ok':'err');
            el.textContent=text;
            var btn=document.getElementById('activateBtn');
            btn.disabled=false;
            btn.textContent='Activate';
          }
          document.getElementById('keyInput').addEventListener('keydown',function(e){
            if(e.key==='Enter')doActivate();
          });
        </script>
      </body></html>
      HTML
    end

    def self.status_html
      <<~HTML
      <!DOCTYPE html>
      <html><head><meta charset="utf-8">
      <style>
        :root{
          --base:#1e1e2e;--mantle:#181825;--crust:#11111b;
          --surface0:#313244;--surface1:#45475a;--surface2:#585b70;
          --overlay0:#6c7086;--text:#cdd6f4;--subtext0:#a6adc8;
          --green:#a6e3a1;--red:#f38ba8;--mauve:#cba6f7;--peach:#fab387;--yellow:#f9e2af;
          --font-mono:'JetBrains Mono','Fira Code','Consolas',monospace;
        }
        *{margin:0;padding:0;box-sizing:border-box}
        body{font:13px/1.5 var(--font-mono);background:var(--base);color:var(--text);
          display:flex;flex-direction:column;height:100vh;overflow:hidden}
        .header{background:var(--crust);border-bottom:1px solid var(--surface0);
          padding:14px 20px;text-align:center}
        .header h1{font-size:13px;font-weight:700;color:var(--mauve);letter-spacing:.5px}
        .body{flex:1;padding:20px;display:flex;flex-direction:column;gap:12px;overflow-y:auto}
        .row{display:flex;align-items:center;gap:10px;font-size:11px}
        .row .label{color:var(--subtext0);min-width:100px;font-weight:600;font-size:10px;letter-spacing:.5px}
        .row .value{color:var(--text);flex:1}
        .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-size:10px;font-weight:700;letter-spacing:.5px}
        .badge.active{background:rgba(166,227,161,.15);color:var(--green)}
        .badge.expired{background:rgba(243,139,168,.15);color:var(--red)}
        .badge.inactive{background:rgba(108,112,134,.15);color:var(--overlay0)}
        .badge.error{background:rgba(249,226,175,.15);color:var(--yellow)}
        .actions{display:flex;flex-direction:column;gap:8px;margin-top:8px}
        .btn{width:100%;padding:8px;border-radius:6px;border:none;font:600 11px var(--font-mono);
          cursor:pointer;transition:all .15s;letter-spacing:.3px}
        .btn-check{background:var(--surface0);color:var(--subtext0)}
        .btn-check:hover{background:var(--surface1);color:var(--text)}
        .btn-manage{background:rgba(203,166,247,.1);color:var(--mauve);border:1px solid rgba(203,166,247,.2)}
        .btn-manage:hover{background:rgba(203,166,247,.2)}
        .btn-deactivate{background:rgba(243,139,168,.08);color:var(--red);border:1px solid rgba(243,139,168,.15)}
        .btn-deactivate:hover{background:rgba(243,139,168,.15)}
        .msg{min-height:24px;font-size:10px;color:var(--subtext0);text-align:center;padding:4px}
        .footer{padding:10px 20px;text-align:center;border-top:1px solid var(--surface0)}
        .footer a{font-size:10px;color:var(--overlay0);cursor:pointer;text-decoration:none}
        .footer a:hover{color:var(--mauve);text-decoration:underline}
      </style>
      </head><body>
        <div class="header">
          <h1>FORM AND FIELD LICENSE</h1>
        </div>
        <div class="body">
          <div class="row">
            <span class="label">STATUS</span>
            <span class="value" id="statusBadge"><span class="badge inactive">Loading...</span></span>
          </div>
          <div class="row">
            <span class="label">LICENSE KEY</span>
            <span class="value" id="keyDisplay" style="font-family:var(--font-mono);letter-spacing:1px">---</span>
          </div>
          <div class="row" id="expiryRow" style="display:none">
            <span class="label">EXPIRES</span>
            <span class="value" id="expiryDisplay">---</span>
          </div>
          <div class="row" id="validatedRow" style="display:none">
            <span class="label">LAST CHECK</span>
            <span class="value" id="validatedDisplay">---</span>
          </div>
          <div class="actions">
            <button class="btn btn-check" onclick="sketchup.revalidate()">Check Now</button>
            <button class="btn btn-manage" onclick="sketchup.manage_subscription()">Manage Subscription</button>
            <button class="btn btn-deactivate" onclick="if(confirm('Deactivate license on this machine?'))sketchup.deactivate_license()">Deactivate This Machine</button>
          </div>
          <div class="msg" id="msg"></div>
        </div>
        <div class="footer">
          <a onclick="sketchup.open_store()">formandfield.lemonsqueezy.com</a>
        </div>
        <script>
          function receiveStatus(s){
            var badge=document.getElementById('statusBadge');
            var cls=s.status==='active'?'active':s.status==='expired'?'expired':
                     s.status==='error'?'error':'inactive';
            var label=s.status?s.status.toUpperCase():'INACTIVE';
            badge.innerHTML='<span class="badge '+cls+'">'+label+'</span>';

            var keyEl=document.getElementById('keyDisplay');
            keyEl.textContent=s.key_tail?('\\u2022\\u2022\\u2022\\u2022\\u2022\\u2022\\u2022\\u2022-'+s.key_tail):'No key stored';

            if(s.expiry){
              document.getElementById('expiryRow').style.display='flex';
              document.getElementById('expiryDisplay').textContent=s.expiry;
            }
            if(s.last_validated){
              document.getElementById('validatedRow').style.display='flex';
              document.getElementById('validatedDisplay').textContent=s.last_validated;
            }
          }
          function showMsg(text){
            document.getElementById('msg').textContent=text;
            setTimeout(function(){document.getElementById('msg').textContent='';},4000);
          }
          // Request status on load
          sketchup.check_status();
        </script>
      </body></html>
      HTML
    end

  end
end
