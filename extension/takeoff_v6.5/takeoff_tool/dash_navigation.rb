module TakeoffTool
  class DashNavigation
    def self.register_callbacks(dialog)

      dialog.add_action_callback('selectEntity') do |_ctx, eid_str|
        e = TakeoffTool.find_entity(eid_str.to_s.to_i)
        if e && e.valid?
          m = Sketchup.active_model; m.selection.clear; m.selection.add(e)
        end
      end

      dialog.add_action_callback('zoomToEntity') do |_ctx, eid_str|
        e = TakeoffTool.find_entity(eid_str.to_s.to_i)
        if e && e.valid?
          m = Sketchup.active_model; m.selection.clear; m.selection.add(e)
          m.active_view.zoom(e)
        end
      end

      # Part-aware isolate: handles part groups that may not be in scan results
      dialog.add_action_callback('zoomToEntities') do |_ctx, ids_str|
        m = Sketchup.active_model
        ents = ids_str.to_s.split(',').map { |id| TakeoffTool.find_entity(id.to_i) }.compact.select(&:valid?)
        m.active_view.zoom(ents) unless ents.empty?
      end

    end
  end
end
