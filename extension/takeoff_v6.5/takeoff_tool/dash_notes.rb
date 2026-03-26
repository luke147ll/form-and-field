# ═══════════════════════════════════════════════════════════════
# DashNotes — Project Notes CRUD, callbacks, model stamp
# Data stored in model.get_attribute('FormAndField', 'ff_notes')
# Author registry in model.get_attribute('FormAndField', 'ff_authors')
# ═══════════════════════════════════════════════════════════════
module TakeoffTool
  module DashNotes

    NOTE_TYPES     = %w[RFI PUNCH FIELD CHANGE SAFETY GENERAL].freeze   unless defined?(NOTE_TYPES)
    URGENCY_LEVELS = %w[CRITICAL HIGH NORMAL LOW].freeze               unless defined?(URGENCY_LEVELS)
    STATUS_VALUES  = %w[OPEN PROGRESS BLOCKED RESOLVED].freeze         unless defined?(STATUS_VALUES)

    STATUS_CYCLE = {
      'OPEN' => 'PROGRESS', 'PROGRESS' => 'BLOCKED',
      'BLOCKED' => 'RESOLVED', 'RESOLVED' => 'OPEN'
    }.freeze unless defined?(STATUS_CYCLE)

    # ─── Load / Save ───

    def self.load_notes
      m = Sketchup.active_model
      return {} unless m
      json = m.get_attribute('FormAndField', 'ff_notes')
      return {} unless json && !json.empty?
      require 'json'
      JSON.parse(json) rescue {}
    end

    def self.save_notes(notes_hash)
      m = Sketchup.active_model
      return unless m
      require 'json'
      m.set_attribute('FormAndField', 'ff_notes', JSON.generate(notes_hash))
    end

    def self.load_authors
      m = Sketchup.active_model
      return {} unless m
      json = m.get_attribute('FormAndField', 'ff_authors')
      return {} unless json && !json.empty?
      require 'json'
      JSON.parse(json) rescue {}
    end

    def self.save_authors(authors_hash)
      m = Sketchup.active_model
      return unless m
      require 'json'
      m.set_attribute('FormAndField', 'ff_authors', JSON.generate(authors_hash))
    end

    # ─── Author ───

    def self.current_author
      user = ENV['USERNAME'] || ENV['USER'] || 'Unknown'
      initials = user.split(/[\s._-]/).map { |w| w[0] }.join.upcase[0..1]
      { 'id' => user, 'name' => initials }
    end

    def self.ensure_author
      auth = current_author
      authors = load_authors
      unless authors[auth['id']]
        authors[auth['id']] = auth['name']
        save_authors(authors)
      end
      auth
    end

    # ─── CRUD ───

    def self.create_note(data)
      notes = load_notes
      auth = ensure_author
      now = Time.now.iso8601
      id = "n_#{Time.now.to_i}_#{rand(1000)}"
      note = {
        'id'           => id,
        'type'         => NOTE_TYPES.include?(data['type']) ? data['type'] : 'GENERAL',
        'urgency'      => URGENCY_LEVELS.include?(data['urgency']) ? data['urgency'] : 'NORMAL',
        'status'       => 'OPEN',
        'title'        => data['title'].to_s.strip,
        'body'         => data['body'].to_s.strip,
        'author_id'    => auth['id'],
        'author_name'  => auth['name'],
        'entity_pid'   => data['entity_pid'],
        'entity_label' => data['entity_label'],
        'created'      => now,
        'updated'      => now,
        'responses'    => []
      }
      notes[id] = note
      save_notes(notes)
      id
    end

    def self.update_note(id, data)
      notes = load_notes
      note = notes[id]
      return unless note
      %w[type urgency status title body entity_pid entity_label].each do |field|
        note[field] = data[field] if data.key?(field)
      end
      note['updated'] = Time.now.iso8601
      notes[id] = note
      save_notes(notes)
    end

    def self.delete_note(id)
      notes = load_notes
      notes.delete(id)
      save_notes(notes)
    end

    def self.add_response(note_id, body_text)
      notes = load_notes
      note = notes[note_id]
      return unless note
      auth = ensure_author
      resp = {
        'id'          => "r_#{Time.now.to_i}_#{rand(1000)}",
        'body'        => body_text.to_s.strip,
        'author_id'   => auth['id'],
        'author_name' => auth['name'],
        'created'     => Time.now.iso8601
      }
      note['responses'] ||= []
      note['responses'] << resp
      note['updated'] = Time.now.iso8601
      notes[note_id] = note
      save_notes(notes)
    end

    def self.cycle_status(note_id, new_status = nil)
      notes = load_notes
      note = notes[note_id]
      return unless note
      if new_status && STATUS_VALUES.include?(new_status)
        note['status'] = new_status
      else
        note['status'] = STATUS_CYCLE[note['status']] || 'OPEN'
      end
      note['updated'] = Time.now.iso8601
      notes[note_id] = note
      save_notes(notes)
    end

    # ─── Tag Link ───

    def self.link_tag_to_note(note_id, tag_eid)
      notes = load_notes
      note = notes[note_id]
      return unless note
      note['tag_eid'] = tag_eid
      note['updated'] = Time.now.iso8601
      notes[note_id] = note
      save_notes(notes)
    end

    # ─── Query ───

    def self.open_count
      load_notes.count { |_id, n| n['status'] != 'RESOLVED' }
    end

    # ─── Model Stamp ───

    def self.stamp_model
      m = Sketchup.active_model
      return unless m
      auth = current_author
      m.set_attribute('FormAndField', 'ff_version', PLUGIN_VERSION)
      m.set_attribute('FormAndField', 'last_author', auth['id'])
      m.set_attribute('FormAndField', 'last_saved', Time.now.iso8601)
      m.set_attribute('FormAndField', 'note_count', open_count)
      stamp = "[FF v#{PLUGIN_VERSION} | #{open_count} open notes | #{auth['id']} | #{Time.now.strftime('%Y-%m-%d %H:%M')}]"
      desc = m.description.to_s
      if desc.include?('[FF ')
        m.description = desc.sub(/\[FF [^\]]*\]/, stamp)
      else
        m.description = desc.empty? ? stamp : "#{desc}\n#{stamp}"
      end
    end

    # ─── Data Send ───

    def self.send_notes_data
      return unless Dashboard.instance_variable_get(:@dialog)
      dialog = Dashboard.instance_variable_get(:@dialog)
      return unless dialog && dialog.visible?
      require 'json'
      notes = load_notes
      authors = load_authors
      payload = { 'notes' => notes.values, 'authors' => authors }
      js = JSON.generate(payload)
      b64 = [js].pack('m0')
      dialog.execute_script("if(typeof receiveNotes==='function')receiveNotes(JSON.parse(atob('#{b64}')))") rescue nil
    end

    # ─── Callbacks ───

    def self.register_callbacks(dialog)

      dialog.add_action_callback('loadNotes') do |_ctx|
        begin
          Dashboard.heartbeat_start('Loading notes...')
          send_notes_data
          Dashboard.heartbeat_stop
        rescue => e
          Dashboard.heartbeat_stop rescue nil
          puts "Takeoff loadNotes error: #{e.message}"
        end
      end

      dialog.add_action_callback('saveNote') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          m.start_operation('Save Note', true)
          if data['id'] && load_notes[data['id']]
            update_note(data['id'], data)
          else
            create_note(data)
          end
          m.commit_operation
          send_notes_data
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          puts "Takeoff saveNote error: #{e.message}"
        end
      end

      dialog.add_action_callback('deleteProjectNote') do |_ctx, note_id_str|
        begin
          m = Sketchup.active_model
          m.start_operation('Delete Note', true)
          delete_note(note_id_str.to_s)
          m.commit_operation
          send_notes_data
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          puts "Takeoff deleteProjectNote error: #{e.message}"
        end
      end

      dialog.add_action_callback('addNoteResponse') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          m.start_operation('Add Note Response', true)
          add_response(data['noteId'], data['body'])
          m.commit_operation
          send_notes_data
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          puts "Takeoff addNoteResponse error: #{e.message}"
        end
      end

      dialog.add_action_callback('cycleNoteStatus') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          m = Sketchup.active_model
          m.start_operation('Update Note Status', true)
          cycle_status(data['noteId'], data['newStatus'])
          m.commit_operation
          send_notes_data
        rescue => e
          Sketchup.active_model.abort_operation rescue nil
          puts "Takeoff cycleNoteStatus error: #{e.message}"
        end
      end

      dialog.add_action_callback('zoomToNoteEntity') do |_ctx, pid_str|
        begin
          m = Sketchup.active_model
          next unless m
          pid_str = pid_str.to_s
          found = false
          m.definitions.each do |defn|
            break if found
            next if defn.image?
            defn.instances.each do |inst|
              next unless inst.respond_to?(:persistent_id)
              if inst.persistent_id.to_s == pid_str
                m.selection.clear
                m.selection.add(inst)
                m.active_view.zoom(m.selection)
                found = true
                break
              end
            end
          end
          puts "[FF Notes] Entity with persistent_id #{pid_str} not found" unless found
        rescue => e
          puts "Takeoff zoomToNoteEntity error: #{e.message}"
        end
      end

      dialog.add_action_callback('getSelectedEntity') do |_ctx|
        begin
          m = Sketchup.active_model
          sel = m.selection.first
          if sel && sel.valid? && sel.respond_to?(:persistent_id)
            pid = sel.persistent_id.to_s
            name = ''
            if sel.respond_to?(:definition)
              name = sel.definition.name.to_s
            end
            name = sel.name.to_s if name.empty? && sel.respond_to?(:name)
            require 'json'
            payload = JSON.generate({ 'pid' => pid, 'label' => name, 'eid' => sel.entityID })
            dialog.execute_script("if(typeof pnReceiveLinkedEntity==='function')pnReceiveLinkedEntity(#{payload})") rescue nil
          else
            dialog.execute_script("if(typeof pnReceiveLinkedEntity==='function')pnReceiveLinkedEntity(null)") rescue nil
          end
        rescue => e
          puts "Takeoff getSelectedEntity error: #{e.message}"
        end
      end

      dialog.add_action_callback('activateNoteTag') do |_ctx, json_str|
        begin
          require 'json'
          data = JSON.parse(json_str.to_s)
          # Map project note type to 3D label type
          type_map = { 'RFI' => 'Question', 'PUNCH' => 'Action', 'FIELD' => 'Note',
                       'CHANGE' => 'Info', 'SAFETY' => 'Warning', 'GENERAL' => 'Note' }
          # Map project note type to a color from the palette
          color_map = { 'RFI' => '#89b4fa', 'PUNCH' => '#fab387', 'FIELD' => '#94e2d5',
                        'CHANGE' => '#cba6f7', 'SAFETY' => '#f38ba8', 'GENERAL' => '#a6adc8' }
          prefill = {
            'text' => data['title'].to_s,
            'label_type' => type_map[data['type']] || 'Note',
            'color' => color_map[data['type']] || '#89b4fa',
            'project_note_id' => data['noteId']
          }
          TakeoffTool.activate_note_tool(prefill)
        rescue => e
          puts "Takeoff activateNoteTag error: #{e.message}"
        end
      end

    end # register_callbacks

  end # DashNotes

  # ─── ModelObserver for stamp on save ───

  class FFModelObserver < Sketchup::ModelObserver
    def onPreSaveModel(_model)
      DashNotes.stamp_model rescue nil
    end
  end

  unless @_ff_model_observer_attached
    Sketchup.active_model.add_observer(FFModelObserver.new) if Sketchup.active_model
    @_ff_model_observer_attached = true
  end

end # TakeoffTool
