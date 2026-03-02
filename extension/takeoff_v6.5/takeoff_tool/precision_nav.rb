module TakeoffTool
  module PrecisionNav
    class NavTool
      def initialize
        @nav = false
        @keys = {}
        @speed = 24.0
        @lx = 0; @ly = 0
        @tid = nil
        @looking = false
      end
      def activate
        @keys = {}; @looking = false
        # Switch to perspective if in parallel projection
        cam = Sketchup.active_model.active_view.camera
        cam.perspective = true unless cam.perspective?
        # Immediately enter fly mode
        @nav = true
        Sketchup.status_text = "NAV ON | Arrows fly, PgUp/Dn rise/fall, +/- speed, click+drag look, N exit"
        @tid = UI.start_timer(0.016, true) {
          next unless @nav && !@keys.empty?
          cam = Sketchup.active_model.active_view.camera
          e = cam.eye; t = cam.target
          fwd = (t - e).normalize
          rt = fwd.cross(Z_AXIS)
          next if rt.length < 0.001
          rt.normalize!
          s = @speed
          mx=0.0;my=0.0;mz=0.0
          if @keys[:f]; mx+=fwd.x*s; my+=fwd.y*s; mz+=fwd.z*s; end
          if @keys[:b]; mx-=fwd.x*s; my-=fwd.y*s; mz-=fwd.z*s; end
          if @keys[:r]; mx+=rt.x*s; my+=rt.y*s; mz+=rt.z*s; end
          if @keys[:l]; mx-=rt.x*s; my-=rt.y*s; mz-=rt.z*s; end
          if @keys[:u]; mz+=s; end
          if @keys[:d]; mz-=s; end
          next if mx==0&&my==0&&mz==0
          o = Geom::Vector3d.new(mx,my,mz)
          cam.set(e.offset(o), t.offset(o), cam.up)
          Sketchup.active_model.active_view.invalidate
        }
      end
      def deactivate(view)
        UI.stop_timer(@tid) if @tid; @tid = nil
        PrecisionNav.on_deactivate
      end
      def resume(view)
        Sketchup.status_text = @nav ? "NAV ON | Arrows fly, PgUp/Dn rise/fall, +/- speed, click+drag look, N exit" : "NAV OFF - press N to fly"
      end
      def onLButtonDown(flags, x, y, view)
        return false unless @nav
        @looking = true
        @lx = x; @ly = y
        true
      end
      def onLButtonUp(flags, x, y, view)
        return false unless @nav
        @looking = false
        true
      end
      def onKeyDown(key, repeat, flags, view)
        if key == 0x4E && repeat == 1
          @nav = !@nav
          @keys = {}; @looking = false
          if @nav
            cam = Sketchup.active_model.active_view.camera
            cam.perspective = true unless cam.perspective?
            Sketchup.status_text = "NAV ON | Arrows fly, PgUp/Dn rise/fall, +/- speed, click+drag look, N exit"
            @tid = UI.start_timer(0.016, true) {
              next unless @nav && !@keys.empty?
              cam = Sketchup.active_model.active_view.camera
              e = cam.eye; t = cam.target
              fwd = (t - e).normalize
              rt = fwd.cross(Z_AXIS)
              next if rt.length < 0.001
              rt.normalize!
              s = @speed
              mx=0.0;my=0.0;mz=0.0
              if @keys[:f]; mx+=fwd.x*s; my+=fwd.y*s; mz+=fwd.z*s; end
              if @keys[:b]; mx-=fwd.x*s; my-=fwd.y*s; mz-=fwd.z*s; end
              if @keys[:r]; mx+=rt.x*s; my+=rt.y*s; mz+=rt.z*s; end
              if @keys[:l]; mx-=rt.x*s; my-=rt.y*s; mz-=rt.z*s; end
              if @keys[:u]; mz+=s; end
              if @keys[:d]; mz-=s; end
              next if mx==0&&my==0&&mz==0
              o = Geom::Vector3d.new(mx,my,mz)
              cam.set(e.offset(o), t.offset(o), cam.up)
              Sketchup.active_model.active_view.invalidate
            }
          else
            UI.stop_timer(@tid) if @tid; @tid = nil
            Sketchup.status_text = "NAV OFF - press N to fly"
          end
          return true
        end
        return false unless @nav
        case key
        when 0x26 then @keys[:f]=true
        when 0x28 then @keys[:b]=true
        when 0x27 then @keys[:r]=true
        when 0x25 then @keys[:l]=true
        when 0x21 then @keys[:u]=true
        when 0x22 then @keys[:d]=true
        when 0xBB then @speed=[@speed*1.25,600.0].min; Sketchup.status_text="NAV | Speed: #{'%.1f' % @speed}"
        when 0xBD then @speed=[@speed*0.8,1.0].max; Sketchup.status_text="NAV | Speed: #{'%.1f' % @speed}"
        end
        true
      end
      def onKeyUp(key, repeat, flags, view)
        return false unless @nav
        case key
        when 0x26 then @keys.delete(:f)
        when 0x28 then @keys.delete(:b)
        when 0x27 then @keys.delete(:r)
        when 0x25 then @keys.delete(:l)
        when 0x21 then @keys.delete(:u)
        when 0x22 then @keys.delete(:d)
        end
        true
      end
      def onMouseMove(flags, x, y, view)
        return false unless @nav && @looking
        dx = x - @lx; dy = y - @ly
        @lx = x; @ly = y
        return true if dx==0 && dy==0
        return true if dx.abs > 50 || dy.abs > 50
        cam = view.camera; e = cam.eye; d = cam.target - e
        dist = d.length; dn = d.normalize
        yaw = -dx * 0.005
        yt = Geom::Transformation.rotation(ORIGIN, Z_AXIS, yaw)
        nf = dn.transform(yt)
        r = Geom::Vector3d.new(nf.y, -nf.x, 0)
        if r.length > 0.001
          r.normalize!
          pitch = -dy * 0.005
          cp = Math.asin(nf.z.clamp(-1.0,1.0))
          wp = (cp+pitch).clamp(-1.4,1.4)
          delta = wp - cp
          if delta.abs > 0.0001
            pt = Geom::Transformation.rotation(ORIGIN, r, delta)
            nf = nf.transform(pt)
          end
        end
        cam.set(e, e.offset(nf, dist), Z_AXIS)
        view.invalidate
        true
      end
      def getMenu(menu); !@nav; end
    end

    @tool_instance = nil
    @enabled = false

    def self.toggle
      @enabled ? disable : enable
    end
    def self.enable
      m = Sketchup.active_model
      return unless m
      @tool_instance = NavTool.new
      m.tools.push_tool(@tool_instance)
      @enabled = true
    end
    def self.disable
      m = Sketchup.active_model
      return unless m
      m.tools.pop_tool
      @tool_instance = nil
      @enabled = false
    end
    def self.enabled?
      @enabled
    end
    def self.on_deactivate
      @enabled = false
      @tool_instance = nil
    end
  end
end
