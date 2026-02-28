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
        preferences_key: "TakeoffStartup",
        width: 420, height: 420,
        left: 200, top: 200,
        resizable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      html_path = File.join(PLUGIN_DIR, 'ui', 'startup.html')
      puts "Startup HTML path: #{html_path}"
      puts "File exists: #{File.exist?(html_path)}"
      @dialog.set_file(html_path)
      @dialog.center

      @dialog.add_action_callback('startScan') do |_ctx|
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
    end

    def self.close
      if @dialog
        @dialog.close
        @dialog = nil
      end
    end
  end
end
