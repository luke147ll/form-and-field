module TakeoffTool
  module ScanBackup

    BACKUP_DIR = File.join(PLUGIN_DIR, 'data')
    MAX_BACKUPS = 3

    # ═══════════════════════════════════════════════════════════
    # save — Write current scan state to a JSON backup file
    #
    # Called after scan completion and after batch reclassifications.
    # Keeps only the last MAX_BACKUPS files per model.
    # ═══════════════════════════════════════════════════════════

    def self.save
      require 'json'
      model = Sketchup.active_model
      return unless model

      sr = TakeoffTool.scan_results
      return if sr.nil? || sr.empty?

      ca = TakeoffTool.category_assignments || {}
      cca = TakeoffTool.cost_code_assignments || {}

      model_name = sanitize_name(model_name_for(model))
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      filename = "scan_backup_#{model_name}_#{timestamp}.json"
      path = File.join(BACKUP_DIR, filename)

      Dir.mkdir(BACKUP_DIR) unless File.directory?(BACKUP_DIR)

      data = {
        'version' => 1,
        'timestamp' => Time.now.to_i,
        'timestamp_str' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'model_name' => model_name,
        'model_path' => model.path,
        'scan_count' => sr.length,
        'category_assignments' => stringify_keys(ca),
        'cost_code_assignments' => stringify_keys(cca),
        'scan_results' => sr.map { |r| serialize_result(r) }
      }

      File.write(path, JSON.generate(data))
      prune_backups(model_name)
      puts "ScanBackup: Saved #{sr.length} results to #{filename}"
    rescue => e
      puts "ScanBackup: Error saving: #{e.message}"
    end

    # ═══════════════════════════════════════════════════════════
    # check_for_recovery — Called on startup after load_scan_from_model
    #
    # Compares the newest backup timestamp with the .skp file's
    # modification time. If backup is newer, the user likely made
    # changes (reclassifications) that weren't saved before a crash.
    # Prompts the user to restore.
    # ═══════════════════════════════════════════════════════════

    def self.check_for_recovery
      model = Sketchup.active_model
      return unless model
      # Only check for models that have been saved to disk
      return if model.path.nil? || model.path.empty?
      return unless File.exist?(model.path)

      model_name = sanitize_name(model_name_for(model))
      backups = find_backups(model_name)
      return if backups.empty?

      latest = backups.last
      backup_mtime = File.mtime(latest).to_i
      model_mtime = File.mtime(model.path).to_i

      # Also check the scan_time attribute saved inside the model
      saved_scan_time = (model.get_attribute('FormAndField', 'scan_time') || 0).to_i
      latest_model_save = [model_mtime, saved_scan_time].max

      # Only prompt if backup is strictly newer
      return if backup_mtime <= latest_model_save

      time_str = Time.at(backup_mtime).strftime('%Y-%m-%d %H:%M:%S')
      result = UI.messagebox(
        "Unsaved scan data found from #{time_str}.\nRestore?",
        MB_YESNO
      )

      restore(latest) if result == IDYES
    rescue => e
      puts "ScanBackup: Error checking recovery: #{e.message}"
    end

    # ═══════════════════════════════════════════════════════════
    # restore — Load scan data from a backup JSON file
    # ═══════════════════════════════════════════════════════════

    def self.restore(path)
      require 'json'
      raw = File.read(path)
      data = JSON.parse(raw)

      # Restore category assignments (keys are entity IDs as strings in JSON)
      ca = {}
      (data['category_assignments'] || {}).each { |k, v| ca[k.to_i] = v }
      TakeoffTool.category_assignments = ca

      # Restore cost code assignments
      cca = {}
      (data['cost_code_assignments'] || {}).each { |k, v| cca[k.to_i] = v }
      TakeoffTool.cost_code_assignments = cca

      # Restore scan results
      sr = (data['scan_results'] || []).map { |r| deserialize_result(r) }
      TakeoffTool.scan_results = sr

      # Persist to entity attributes so a future .skp save captures it
      TakeoffTool.save_scan_to_model

      count = sr.length
      puts "ScanBackup: Restored #{count} results from #{File.basename(path)}"
      UI.messagebox("Restored #{count} scan results from backup.")

      # Reload supporting data and open dashboard
      TakeoffTool.load_saved_assignments
      TakeoffTool.load_master_categories
      TakeoffTool.load_master_subcategories
      TakeoffTool.load_manual_measurements
      TakeoffTool.open_dashboard if count > 0
    rescue => e
      puts "ScanBackup: Error restoring: #{e.message}"
      UI.messagebox("Error restoring backup: #{e.message}")
    end

    # ═══════════════════════════════════════════════════════════
    # Private helpers
    # ═══════════════════════════════════════════════════════════

    private

    def self.serialize_result(r)
      h = {}
      r.each do |k, v|
        key = k.to_s
        if k == :parsed && v.is_a?(Hash)
          h[key] = {}
          v.each do |pk, pv|
            h[key][pk.to_s] = pv.is_a?(Symbol) ? pv.to_s : pv
          end
        elsif v.is_a?(Symbol)
          h[key] = v.to_s
        else
          h[key] = v
        end
      end
      h
    end

    SYMBOL_FIELDS = %w[source].freeze
    PARSED_SYMBOL_FIELDS = %w[confidence].freeze

    def self.deserialize_result(h)
      r = {}
      h.each do |k, v|
        key = k.to_sym
        if k == 'parsed' && v.is_a?(Hash)
          parsed = {}
          v.each do |pk, pv|
            sym = pk.to_sym
            if PARSED_SYMBOL_FIELDS.include?(pk) && pv.is_a?(String)
              parsed[sym] = pv.to_sym
            else
              parsed[sym] = pv
            end
          end
          r[key] = parsed
        elsif SYMBOL_FIELDS.include?(k) && v.is_a?(String)
          r[key] = v.to_sym
        else
          r[key] = v
        end
      end
      r
    end

    def self.stringify_keys(hash)
      result = {}
      hash.each { |k, v| result[k.to_s] = v }
      result
    end

    def self.sanitize_name(name)
      name.gsub(/[^a-zA-Z0-9_-]/, '_')[0..40]
    end

    def self.model_name_for(model)
      if model.path && !model.path.empty?
        File.basename(model.path, '.skp')
      else
        'Untitled'
      end
    end

    def self.find_backups(model_name)
      pattern = File.join(BACKUP_DIR, "scan_backup_#{model_name}_*.json")
      Dir.glob(pattern).sort
    end

    def self.prune_backups(model_name)
      backups = find_backups(model_name)
      while backups.length > MAX_BACKUPS
        old = backups.shift
        File.delete(old) rescue nil
        puts "ScanBackup: Pruned old backup #{File.basename(old)}"
      end
    end
  end
end
