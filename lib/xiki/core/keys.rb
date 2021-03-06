require 'xiki/core/pause_means_space'
require 'xiki/core/line'
require 'xiki/core/text_util'

module Xiki
  # Methods for defining keyboard shortcuts
  class Keys

    @@key_queue = []   # For defining menus (must be done in reverse)
    @@source ||= {}   # Stores source for new unified key defs

    def self.source
      @@source
    end

    def self.api
      '
      > Summary
      | Ways to use the Keys class, to define keyboard shortcuts etc.  Remember
      | that with xiki shortcuts you hold down the control key and "type the
      | acronym" (the first letter in each word) while holding down the control
      | key.
      |
      > Define keyboard shortcuts
      | Defines the key Control-e Control-y
      |
      |   Keys.enter_name { View << "Steve" }
      |
      | Defines the key Control-e Control-y (with no mnemonic)
      |
      |   Keys.EN { View << "Steve again" }
      |
      > Where to put them
      | You can put keyboard shortcuts into any file that gets required by xiki.
      | For example, you could create a file like this:
      |
      - @~/my_xiki_stuff/
        - keys.rb
          | # My shortcuts
          | Keys.enter_name { View << "Steve" }
          | Keys.enter_yay { View << "Yay" }
      |
      | Then you could require this file when xiki loads by adding this line:
      |
      - @~/.el4r/
        - init.rb
          | require "~/my_xiki_stuff/keys"
      '
    end


    # Handles Keys.to_foo etc.

    def self.method_missing(meth, *args, &block)
      return if ! $el

      # Accept it if block but no args
      meth = meth.to_s

      meth_orig = meth.dup


      # Delegate to super unless arg is single symbol
      unless args.size == 0 or (args.size == 1 and args[0].is_a? Symbol)
        return super(meth, *args, &block)
      end

      meth_title = meth.gsub('_', ' ').gsub(/\b\w/) {|s| s.upcase}
      menu, item = meth_title.match(/(.+?) (.+)/)[1..2] if meth_title =~ /. ./

      # If 1st word is 'isearch', use it as map
      if meth =~ /^search_/
        @@key_queue << ["Search", item]
        meth.sub! /^search_/, ''
        meth = self.words_to_letters meth
        args = [:isearch_mode_map]
      elsif meth =~ /[A-Z]/   # If capital letters
        # Don't convert
      elsif meth =~ /_/   # Add menu item, if more than one word

        if args.size == 0   # If global keymap
          # Make lisp function
          $el.defun(meth.to_sym, :interactive=>true) do
            block.call
          end
          @@key_queue.<< [menu, item] if item !~ /^\d+$/   # Don't add to+1 etc. to menu bar
        end

        # Change 'to_foo' to 'TF' etc
        meth = self.words_to_letters meth
      end

      keys_raw = self.translate_keys meth   # Translate to 'C-t C-f' etc

      keys = $el.kbd keys_raw   # Translate to actual control keys

      map = :global_map   # Default to global keymap

      # Use keymap if symbol passed as 1st arg
      map = args.shift if args[0] and args[0].class == Symbol
      # If they just passed a string, use it as code
      if args and (args.size == 1) and !block
        self.map_to_eval keys_raw, args[0]
        return
      end

      #     # Add menus for key shortcuts - seems kind of pointless in retrospect
      #     if map == :global_map && meth_orig =~ /^[a-z]/
      #       Launcher.add(meth.downcase, &block)
      #       Launcher.add(meth_orig, &block)   # if meth_orig =~ /^[a-z]/
      #     end

      # Define key
      begin
        self.define_key map, keys_raw, keys, &block
        "- key was defined: #{keys_raw}"
      rescue Exception => e
        return if map != :global_map || meth !~ /([A-Z])([A-Z]?)./   # Only global map and 2 control keys
        message = e.message
        prefix = message[/"Key sequence .+? starts with non-prefix key (.+?)"/, 1]
        return if prefix.nil?

        prefix = $el.kbd(prefix)

        begin   # If it appears to be a prefix key (already defined)
          $el.global_unset_key prefix
          #         $el.define_key map, keys, &block
          self.define_key map, keys_raw, keys, &block
          #         self.define_key map, keys, &block

        rescue Exception => e
          Ol << "e (inner): #{e.inspect}"
        end

      end
    end

    def self.map_to_eval keys_raw, code
      $el.el4r_lisp_eval"
        (global-set-key (kbd \"#{keys_raw}\")  (lambda () (interactive)
          (el4r-ruby-eval \"#{code}\" )
        ))
        "
    end

    def self.translate_keys txt
      l = txt.scan(/_?\w/)
      l.collect! { |b|
        case b
        when /^_([A-Z])/
          "M-" + $1.downcase
        when /^([a-z])$/
          $1
        else
          "C-" + b.downcase
        end
      }
      l.join " "
    end

    def self.set *args, &block

      # Keys is always first arg
      keys = args.shift
      if args.size > 0   # If 2nd arg, use it
        self.map_to_eval keys, args[0]
      else   # Otherwise, use block
        $el.define_key :global_map, $el.kbd(keys), &block
      end
    end

    # Gets input from user.
    #
    # Sample usages:
    # Keys.input   # Terminated by enter
    # Keys.input "Type something: "
    # Keys.input :chars=>1   # Just one char
    # Keys.input :timed=>1   # Terminated by pause (and convert control to alpha)
    # Keys.input :optional=>1   # Terminated by pause
    #   - A pause at the beginning will result in no input (nil)
    def self.input *args

      prompt = args.shift if args[0].is_a?(String)

      options = args[0] || {}

      return self.input_with_choices(options) if options[:choices]

      Cursor.remember :before_input

      Cursor.hollow

      prompt ||= options[:prompt] || "Input: "

      if options[:chars]
        char = $el.char_to_string(
          self.remove_control($el.read_char(prompt))).to_s
        Cursor.restore :before_input
        return char
      end

      # If simple un-timed input, just get string and return it...

      unless options[:timed] || options[:optional]
        Cursor.restore :before_input
        c = $el.read_string(prompt, options[:initial_input])
        return c
      end

      # :timed or :optional option...

      keys = ""

      $el.elvar.inhibit_quit = true
      c = nil

      # If not optional, wait for input initially
      unless options[:optional]
        c = $el.read_char(prompt)
        keys = self.to_letter(c)
      end

      if c == 7
        Cursor.restore :before_input
        $el.elvar.inhibit_quit = nil
        $el.keyboard_quit
      end

      while(c = $el.read_char("#{prompt}#{keys}", nil, 0.35))
        keys += self.to_letter(c)
        if c == 7
          Cursor.restore :before_input
          $el.elvar.inhibit_quit = nil
          $el.keyboard_quit
        end
      end
      $el.elvar.inhibit_quit = nil
      Cursor.restore :before_input

      $el.message ""
      # If nothing, return nil
      keys == "" ? nil : keys
    end

    # TODO: finish - look at spec
    def self.input_with_choices options
      prompt = options[:prompt] ? "#{options[:prompt]} " : ""
      prompt << options[:choices].map{|i|
        "[#{i.first[/./]}]#{i.first[/.(.+)/,1]}"}.
        join(', ')
      c = Keys.input :chars=>1, :prompt=>prompt
      options[:choices].find{|i| i.first =~ /^#{c}/}[1]
    end

    def self.to_letter ch, options=nil
      verbose = options && options[:verbose]
      return nil if ch.nil?
      if ch == 0
        verbose = nil if verbose
        ch = 32
      elsif ch < 27
        verbose = "C-" if verbose
        ch += 96
      elsif 67108896 <= ch and ch <= 67108925
        verbose = "C-" if verbose
        ch -= 67108864
      elsif 134217825 <= ch and ch <= 134217850
        verbose = "M-" if verbose
        ch -= 134217728
      else
        verbose = nil if verbose
      end
      return "#{verbose}#{ch.chr}"
      ch.chr
    end

    # Converts any control keys in input to normal keys.
    # Example: "\C-x" => "x"
    def self.remove_control ch
      ch += 96 if ch < 27
      ch
    end

    def self.read_char_maybe
      loc = $el.read_char("Optionally type a char:", nil, 0.35)
      $el.message ""
      return if loc.nil?

      # Convert control chars to the corresponding letters
      loc += 96 if(1 <= loc and loc <= 26)
      loc = self.remove_control loc
      loc
    end

    def self.insert_code
      keys = $el.read_key_sequence("Type some keys, to insert the corresponding code: ")

      # If C-n or C-p, pretend like they were mapped to xiki functions

      if keys == "\cn"
        return View << 'Line.next'
      elsif keys == "\cp"
        return View << 'Line.previous'
      end

      proc = self.proc_from_key keys

      # If lisp, enter lisp?
      if proc.nil?
        keys = $el.key_binding(keys)
        if keys
          return View.insert($el.prin1_to_string(keys))
        else
          $el.beep
          return View.message("Key is unmapped")
        end
      end

      code = Code.to_ruby(proc)
      code.gsub! 'proc { ', ''
      code.sub! /.*{(.+)}.*/, "\\1"
      code.gsub! ' }', ''
      code.gsub! '(:blink => (true))', ''
      code.strip!

      View << code
    end

    def self.jump_to_code
      keys = $el.read_key_sequence("Type some keys, to jump to the corresponding code: ")

      # If was defined with unified, pull from Keys.source...

      letters = self.sequence_to_string keys
      if source = Keys.source[letters]
        file, line = source.split ':'
        Location.go file
        View.to_line line.to_i
        return
      end

      proc = self.proc_from_key keys
      if proc.nil?
        $el.beep
        return View.message("Key isn't mapped in Xiki")
      end

      file, line = Code.location_from_proc proc
      file = "#{Xiki.dir}#{file}" unless file =~ /^\//
      Location.go file
      View.to_line line.to_i
      Effects.blink(:what=>:line)
    end

    def self.proc_from_key keys
      code = $el.prin1_to_string($el.key_binding(keys))
      # If it is a call to elisp
      id = code[/el4r-ruby-call-proc-by-id.+?([_0-9]+)/, 1]
      return nil if id.nil?

      ObjectSpace._id2ref(id.to_i)
    end

    def self.timed_insert options={}
      prefix = Keys.prefix
      # If prefix of 0, insert in a way that works with macros
      case prefix
      when nil   # Do nothing
      when :u   # Do pause for space
        PauseMeansSpace.go
        return
      when 0
        View.insert Keys.input(:prompt => "Insert text to insert: ")
        return
      else   # If other prefix, insert single char n times
        c = View.read_char("Insert single char to insert #{prefix} times: ").chr
        prefix.times do
          View.insert c
        end
        return
      end

      Cursor.remember :before_q
      Cursor.box
      # This is slow in mac emacs 23/24 :(
      # Cursor.green

      # Get first char and insert
      c = $el.read_char("insert text (pause to exit): ").chr
      inserted = "#{c}"

      View.insert c

      # While no pause, insert more chars
      while(c = $el.read_char("insert text (pause to exit): ", nil, 0.36))
        inserted += c.chr
        View.insert c.chr
      end

      $el.elvar.qinserted = inserted
      $el.message "input ended"

      Cursor.restore :before_q

      # Store in hash by first letter for use by enter_yank

      Clipboard.save_by_first_letter inserted   # Store for retrieval with enter_yank

    end

    def self.as name
      Clipboard.copy("#{name}")
      Bookmarks.save("$#{name}")
      Bookmarks.save("$_#{name}")
      View.save("#{name}")
    end

    def self.insert_from_q
      ($el.elvar.current_prefix_arg || 1).times do
        View.insert($el.elvar.qinserted)
      end
    end

    def self.prefix_or_0 options={}
      pre = Keys.prefix
      pre.is_a?(Fixnum) ? pre : 0
    end

    #
    # Set prefix, or append it (space-delimited) if one already there.
    #
    def self.add_prefix new_prefix
      prefix = self.prefix

      return self.prefix = new_prefix if ! prefix   # If none there already, just set it

      self.prefix = "#{self.prefix} #{new_prefix}"
    end

    def self.prefix options={}
      return nil if ! $el
      pre = $el.elvar.current_prefix_arg
      return nil unless pre

      # Clear prefix if :clear
      $el.elvar.current_prefix_arg = nil if options[:clear]
      str = pre.to_s

      return :u if str == "u"

      if str =~ /^\(/
        return :uu if str == "(16)"
        return :uuu if str == "(64)"
        return :u
      end

      return :- if "#{pre}" == "-"
      return pre
    end

    def self.prefix= to
      $el.elvar.current_prefix_arg = to
    end

    # Whether C-u was held down before this
    def self.prefix_u?
      self.prefix == :u
    end

    # Whether C-u was held down before this
    # Deprecated
    def self.prefix_u options={}
      result = self.prefix == :u
      self.clear_prefix if options[:clear]
      result
    end

    def self.up? options={}
      self.prefix_u options
    end

    def self.update? options={}
      # TODO update so prefix can have multiple values, like C-u and "update"
      #   for when C-u as+update
      #   (space-separated list)?
      #     "u update"
      self.prefix == "update"
    end

    def self.delete? options={}
      self.prefix == "delete"
    end

    def self.open? options={}
      self.prefix == "open"
    end

    def self.prefix_n options={}
      pre = self.prefix(options)
      return pre if pre.is_a?(Fixnum)
      return $&.to_i if pre.is_a?(String) && pre =~ /\d+/
      nil
    end

    def self.prefix_uu
      self.prefix == :uu
    end

    def self.clear_prefix
      $el.elvar.current_prefix_arg = nil
    end

    # Prompts for input of bookmark name, then returns its file path.
    # If bookmark is to a file, it returns the enclosing dir.
    # Keys.bookmark_as_path   # If user typed "ru"...
    #   /notes/ruby/
    # Keys.bookmark_as_path :include_file=>1   # If user typed "ru"...
    #   /notes/ruby/index.notes
    # Keys.bookmark_as_path :prompt=>"Enter something"   # Show message
    # Keys.bookmark_as_path :bm=>"ru"   # Don't prompt
    # Keys.bookmark_as_path :bm=>"."   # Current dir works
    #   /projects/xiki/lib/xiki/core/
    def self.bookmark_as_path options={}
      bm = options[:bm] || Keys.input(:timed=>true, :prompt=>options[:prompt]||"Enter a bookmark: ")

      if bm == " "   # If space, return special token
        return :space
      elsif bm == "/"   # If slash, return special token
        return :slash
      elsif bm == "x"   # If slash, return special token
        return Xiki.dir
      elsif bm == ","   # If slash, return special token
        return :comma
      elsif bm =~ /^\.+$/   # If .+ do tree in current dir
        dir = View.dir :force_slash
        (bm.size - 1).times do
          dir.sub! /\/$/, ''   # Remove / on end if there
          dir.sub! /[^\/]+$/, ''   # Remove dir
        end
        dir.sub! /^$/, '/'   # If nothing left, use root (/)
        return dir
      end

      dir = Bookmarks.expand "$#{bm}"
      if dir.nil?   # If no dir, return nil
        View.beep "- Bookmark '#{bm}' doesn't exist."
        return :bookmark_doesnt_exist
      end

      unless options[:include_file]
        dir = Bookmarks.dir_only dir
        dir << "/" unless dir =~ /\/$/
      end
      dir

    end

    def self.prefix_times prefix=self.prefix, &block
      result = case prefix
        when nil, :u, :uu, :uuu
          1
        else
          prefix
        end
      result.times{ block.call } if block
      result
    end

    def self.add_menubar_items
      @@key_queue.reverse.each do |i|
        Menu.add_menubar_item [Menu::ROOT_MENU, i[0]], i[1], "#{i[0].downcase}-#{i[1].downcase.gsub(' ', '-')}"
      end
      @@key_queue = []
    end

    def self.char
      $el.elvar.inhibit_quit = true
      ch_initial = $el.read_event.to_s
      $el.elvar.inhibit_quit = nil

      if ch_initial =~ /^\d+$/   # If a number, assign it to raw
        ch_raw = ch_initial.to_i
        if 134217825 <= ch_raw and ch_raw <= 134217850  # If meta (out of elisp range)
          return ["meta_#{(ch_raw - 134217728).chr}".to_sym, nil]
        end

        # Special check for C-. and other sequences
        ch = if ch_raw == 67108910
          :control_period
        elsif ch_raw >= 67108912 && ch_raw <= 67108921   # If between C-0 and C-9
          (ch_raw - 67108864).chr
        elsif ch_raw == 67108911
          :control_slash
        else
          # If char is over the elisp max, try to interpret it as Meta
          $el.char_to_string(ch_raw)
        end
        return [ch, ch_raw]

      elsif ['left', 'right', 'up', 'down', ].member?(ch_initial)
        return [ch_initial.to_sym, 0]   # Arbitrary indicator for arrow keys

      elsif ch_initial == "A-return"
        return [:meta_return, 13]

      elsif ch_initial == "C-return"
        return [:control_return, 13]

      elsif ch_initial == "return"
        return [:return, 13]

      elsif ch_initial == "backspace"
        return [:backspace, 127]

      elsif ch_initial == "tab"
        return ["\t", 9]

      else   # Probably a mouse event
        return [nil, nil]
      end

    end

    def self.words_to_letters txt
      TextUtil.camel_case(txt).gsub(/[a-z]/, '')
    end

    def self.last nth=1
      $el.el4r_lisp_eval("(elt (recent-keys) (- (length (recent-keys)) #{nth}))").to_s
    end

    def self.before_last
      $el.el4r_lisp_eval("(elt (recent-keys) (- (length (recent-keys)) 2))").to_s
    end

    def self.history
      $el.view_lossage
      View.flash "- Showed recently-typed keys in other view!", :times=>4
    end

    def self.isearch_prefix shortcut_length=2
      # TODO Make search.stop set Keys.prefix (call .isearch_prefix)
        # Keys.prefix = self.isearch_prefix
      # and don't call .isearch_prefix

      # What about shortcut_length though?  Would we get weird results for search_foo_foo shortcuts? - just try it for now

      # Return it if character before key shortcut was C-u or C-0 - C-9...
      char = Keys.last(shortcut_length+1).to_i
      return :u if char == 21
      return :- if char == 67108909
      return (char - 67108912) if char >= 67108912 && char <= 67108921

      nil
    end

    def self.human_readable txt
      txt.split(/[^a-z]/i).map{|o| "Control-#{o[/./].upcase}"}.join(" ")
    end



    private

    def self.define_key map, keys_raw, keys, &block
      $el.define_key map, keys, &block
      self.define_key_extra map, keys_raw, &block
    end

    # Maybe define key again, if it starts with C-i for compatibility with control-lock.
    def self.define_key_extra map, keys_raw, &block
      return if keys_raw !~ /\bC-i\b/

      keys_raw = keys_raw.gsub /\bC-i\b/, "C-<tab>"
      wrapper = lambda { block.call }

      $el.define_key map, $el.kbd(keys_raw), &wrapper
    end

    def self.log options={}
      codes = $el.recent_keys.to_a.reverse

      if ! options[:raw]   # Unless they wanted it raw
        codes = codes[0..30]   # Only show a few
        # Turn into letters
        codes = codes.map{|o| Keys.to_letter o, :verbose=>1 }

        codes = codes.map{|o| "| #{o}\n" }.join("")
        codes.gsub!(/  $/, " space")
      end

      codes
    end

    def self.sequence_to_string keys
      keys.split('').map{|o| Keys.to_letter(o.sum).upcase}.join('')
    end

    # Filters a list if items based on one or a few keys.
    # To match, it finds the note file starting
    # with the first char, and containing the second.  So, "r" or
    # "rb" would match "ruby".
    def self.filter list, keys
      regex1 = Regexp.new "^#{keys}"
      keys = keys.split(//)
      first = keys.shift
      regex2 = "^#{first}"
      keys.each{|o| regex2 << ".*#{o}"}
      regex2 = Regexp.new regex2
      found = list.find{|o| o =~ regex1}
      found ||= list.find{|o| o =~ regex2}
      found
    end

  end
end
