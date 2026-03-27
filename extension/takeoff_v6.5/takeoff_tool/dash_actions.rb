module TakeoffTool
  class DashActions
    def self.register_callbacks(dialog)

      dialog.add_action_callback('exportCSV') do |_ctx|
        Exporter.export_csv(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      dialog.add_action_callback('exportHTML') do |_ctx|
        Exporter.export_html(TakeoffTool.scan_results, TakeoffTool.category_assignments, TakeoffTool.cost_code_assignments)
      end

      dialog.add_action_callback('exportModel') do |_ctx, json_str|
        begin
          require 'json'
          opts = JSON.parse(json_str.to_s)
          Exporter.export_model(
            scan_results: TakeoffTool.scan_results,
            category_assignments: TakeoffTool.category_assignments,
            cost_code_assignments: TakeoffTool.cost_code_assignments,
            include_takeoff: opts['takeoff'],
            include_measurements: opts['measurements'],
            include_notes: opts['notes']
          )
        rescue => e
          puts "[FF] exportModel error: #{e.message}"
          UI.messagebox("Export failed: #{e.message}")
        end
      end

      dialog.add_action_callback('rescan') do |_ctx, tpl_str|
        Dashboard.invalidate_measurement_cache
        tpl = tpl_str.to_s.strip
        if !tpl.empty? && defined?(CategoryTemplates)
          puts "Takeoff: Applying template '#{tpl}' before scan"
          CategoryTemplates.apply_template(tpl)
        end
        TakeoffTool.run_scan
      end

      dialog.add_action_callback('listTemplates') do |_ctx|
        names = defined?(CategoryTemplates) ? CategoryTemplates.list : []
        require 'json'
        safe = JSON.generate(names).gsub('</') { '<\\/' }
        Dashboard.dialog.execute_script("receiveTemplates(#{safe})")
      end

      dialog.add_action_callback('openHyperParse') do |_ctx|
        HyperParser.show_dialog
      end

    end
  end
end
