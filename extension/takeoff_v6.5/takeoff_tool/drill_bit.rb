module TakeoffTool
  module DrillBit
    class DrillBitTool
      def initialize
        @highlight = nil
        @stack = []
        @depth = 0
      end
      def activate
        @highlight = nil; @stack = []; @depth = 0
        Sketchup.status_text = "DRILL BIT | Hover to detect, click to open and select, N to exit"
      end
      def deactivate(view)
        @highlight = nil
        DrillBit.on_deactivate
      end
      def onMouseMove(flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        path = ph.path_at(0)
        return true unless path && path.length > 0
        new_stack = []
        path.each do |ent|
          if ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)
            new_stack << ent
          end
        end
        if new_stack.length > 0 && new_stack != @stack
          @stack = new_stack
          @depth = @stack.length - 1
          highlight_current(view)
        end
        true
      end
      def onKeyDown(key, repeat, flags, view)
        if key == 0x4E && repeat == 1
          Sketchup.active_model.select_tool(nil)
          return true
        end
        case key
        when 0x26
          if @depth < @stack.length - 1
            @depth += 1; highlight_current(view)
          end
        when 0x28
          if @depth > 0
            @depth -= 1; highlight_current(view)
          end
        when 0x25
          siblings = get_siblings
          if siblings.length > 1
            idx = siblings.index(@stack[@depth]) || 0
            idx = (idx - 1) % siblings.length
            @stack[@depth] = siblings[idx]
            highlight_current(view)
          end
        when 0x27
          siblings = get_siblings
          if siblings.length > 1
            idx = siblings.index(@stack[@depth]) || 0
            idx = (idx + 1) % siblings.length
            @stack[@depth] = siblings[idx]
            highlight_current(view)
          end
        end
        true
      end
      def onKeyUp(key, repeat, flags, view); true; end
      def onLButtonDown(flags, x, y, view)
        return true unless @highlight && @stack.length > 0
        model = Sketchup.active_model
        target = @stack[@depth]
        parent_path = @stack[0...@depth]
        model.select_tool(nil)
        model.active_path = nil
        if parent_path.length > 0
          begin
            model.active_path = parent_path
          rescue => e
            puts "active_path= error: #{e.message}"
          end
        end
        model.selection.clear
        model.selection.add(target)
        name = target.is_a?(Sketchup::ComponentInstance) ? target.definition.name : (target.name.empty? ? "Group" : target.name)
        Sketchup.status_text = "SELECTED: #{name} | Right-click for options, Esc to close edit"
        true
      end
      def draw(view)
        return unless @highlight
        bb = @highlight.bounds
        return if bb.empty?
        pts = []
        (0..7).each { |i| pts << bb.corner(i) }
        view.line_stipple = ""
        view.line_width = 3
        view.drawing_color = Sketchup::Color.new(255, 255, 0)
        view.draw_line(pts[0], pts[1])
        view.draw_line(pts[1], pts[3])
        view.draw_line(pts[3], pts[2])
        view.draw_line(pts[2], pts[0])
        view.draw_line(pts[4], pts[5])
        view.draw_line(pts[5], pts[7])
        view.draw_line(pts[7], pts[6])
        view.draw_line(pts[6], pts[4])
        view.draw_line(pts[0], pts[4])
        view.draw_line(pts[1], pts[5])
        view.draw_line(pts[2], pts[6])
        view.draw_line(pts[3], pts[7])
      end
      def getMenu(menu); true; end
      private
      def highlight_current(view)
        return if @stack.empty? || @depth >= @stack.length
        @highlight = @stack[@depth]
        name = @highlight.is_a?(Sketchup::ComponentInstance) ? @highlight.definition.name : (@highlight.name.empty? ? "Group" : @highlight.name)
        Sketchup.status_text = "DRILL [#{@depth+1}/#{@stack.length}] #{name} | Up/Dn drill, L/R siblings, click to open+select"
        view.invalidate
      end
      def get_siblings
        return [] if @stack.empty? || @depth >= @stack.length
        current = @stack[@depth]
        if @depth == 0
          parent_ents = Sketchup.active_model.active_entities
        else
          parent = @stack[@depth - 1]
          if parent.is_a?(Sketchup::ComponentInstance)
            parent_ents = parent.definition.entities
          elsif parent.is_a?(Sketchup::Group)
            parent_ents = parent.entities
          else
            return [current]
          end
        end
        parent_ents.select { |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        }
      end
    end

    @tool_instance = nil
    @active = false

    def self.activate
      return if @active
      TakeoffTool::PrecisionNav.disable if TakeoffTool::PrecisionNav.enabled?
      m = Sketchup.active_model
      return unless m
      @tool_instance = DrillBitTool.new
      m.tools.push_tool(@tool_instance)
      @active = true
    end
    def self.deactivate
      return unless @active
      Sketchup.active_model.select_tool(nil)
      @tool_instance = nil
      @active = false
    end
    def self.toggle
      @active ? deactivate : activate
    end
    def self.active?
      @active
    end
    def self.on_deactivate
      @active = false
      @tool_instance = nil
    end
  end
end
