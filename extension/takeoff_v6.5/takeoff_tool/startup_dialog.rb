module TakeoffTool
  module StartupDialog
    @dialog = nil

    def self.show
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Form and Field",
        preferences_key: "TakeoffStartup3",
        width: 420, height: 480,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      html_path = File.join(PLUGIN_DIR, 'ui', 'startup.html')
      puts "Startup HTML path: #{html_path}"
      puts "File exists: #{File.exist?(html_path)}"
      @dialog.set_file(html_path)
      @dialog.center

      @dialog.add_action_callback('startScan') do |_ctx, tpl_str|
        tpl = tpl_str.to_s.strip
        if !tpl.empty? && defined?(CategoryTemplates)
          puts "Takeoff: Applying template '#{tpl}' before scan"
          CategoryTemplates.apply_template(tpl)
        end
        dlg = @dialog
        TakeoffTool.run_scan(dlg)
        # Close startup dialog after scan completes
        if dlg
          begin; dlg.close; rescue; end
        end
        @dialog = nil
      end

      @dialog.add_action_callback('cancel') do |_ctx|
        @dialog.close
        @dialog = nil
      end

      @dialog.show

      # Send template list after dialog is visible
      UI.start_timer(0.3) do
        if @dialog && @dialog.visible?
          names = defined?(CategoryTemplates) ? CategoryTemplates.list : []
          require 'json'
          safe = JSON.generate(names).gsub("'", "\\\\'")
          @dialog.execute_script("receiveTemplates('#{safe}')") rescue nil
        end
      end
    end

    def self.close
      if @dialog
        @dialog.close
        @dialog = nil
      end
    end
  end
end
