
# A syntax highlighter compatible with textmate bundles.
# Copyright 2007 Daniel Lucraft.

require 'lib/syntax/grammar'
require 'lib/syntax/scope'
require 'lib/syntax/parser'

module Redcar
  module Syntax
    include DebugPrinter
    
    def self.load_grammars
      # FIXME to not load all grammars upfront
      if File.exist?("cache/grammars.dump")
        str = File.read("cache/grammars.dump")
        @grammars = Marshal.load(str)
        @grammars_by_extension ||= {}
        @grammars.each do |name, gr|
          gr.file_types.each do |ext|
            @grammars_by_extension["."+ext] = @grammars[name]
          end
        end
      else
        @grammars ||= {}
        @grammars_by_extension ||= {}
        plists = []
        if @grammars.keys.empty?
          Dir.glob("textmate/Bundles/*/Syntaxes/*").each do |file|
            puts "loading #{file}"
            xml = IO.readlines(file).join
            plist = Redcar::Plist.plist_from_xml(xml)
            gr = plist[0]
            plists << plist
            @grammars[gr['name']] = Redcar::Syntax::Grammar.new(plist[0])
            gr['fileTypes'].each do |ext|
              @grammars_by_extension["."+ext] = @grammars[gr['name']]
            end
          end
        end
        str = Marshal.dump(@grammars)
        File.open("cache/grammars.dump", "w") do |f|
          f.puts str
        end
      end
    end
    
    def self.grammar(options)
      if options[:name]
        @grammars[options[:name]]
      elsif options[:extension]
        @grammars_by_extension[options[:extension]]
      end
    end
    
    def self.grammar_names
      @grammars.keys
    end
  end
end


Redcar.hook :startup do
  Redcar::Syntax.load_grammars
  Redcar.MainToolbar.append_combo(Redcar::Syntax.grammar_names) do |_, tab, grammar|
    tab.set_grammar(Redcar::Syntax.grammar(:name => grammar))
  end
end


module Redcar
  class TextTab
    keymap "super s", :scope_tooltip
    keymap "super-shift S", :select_scope
    keymap "control-super s", :print_scope_tree
    keymap "alt-super s", :reparse_tab
    
    attr_accessor :scope_tree, :parser
    
    def reparse_tab
      colour
      debug_puts @scope_tree.pretty
    end
    
    def print_scope_tree
      puts @scope_tree.pretty
    end
    
    def scope_tooltip
      scope = scope_at_cursor
      puts "scope_at_cursor: #{scope.inspect}"
      tooltip_at_cursor(scope.hierarchy_names.join("\n"))
    end
    
    def select_scope
      if selected?
        x, y = selection_bounds
        xi = iter(x)
        yi = iter(y)
        scope = Syntax::Scope.common_ancestor(@scope_tree.scope_at(TextLoc.new(xi.line, xi.line_offset)),
                                              @scope_tree.scope_at(TextLoc.new(yi.line, yi.line_offset)))
      else
        scope = scope_at_cursor
      end
      if scope
        end_iter = iter(scope.end)
        unless scope.end
          end_iter = iter(end_mark)
        end
        select(iter(scope.start), end_iter)
      end
    end
    
    def scope_at_cursor
      scope = @scope_tree.scope_at(TextLoc.new(cursor_line, cursor_line_offset))
    end
    
    alias :initialize_without_syntax :initialize
    def initialize(pane)
      initialize_without_syntax(pane)
      
      set_theme(Theme.default_theme)
      if ext = File.extname(@filename||"")
        debug_puts "extension: #{ext}"
        set_grammar(Syntax.grammar(:extension => ext))
      end
      
#       @buffer.signal_connect("inserted_text") do |widget, iter, text, length|
#         Redcar.event :tab_modified, self unless @was_modified
#         Redcar.event :tab_changed
#         store_insertion(iter, text, length)
#         @was_modified = true
#       end
      
      @buffer.signal_connect("insert_text") do |widget, iter, text, length|
#         @buffer.signal_emit("inserted_text", iter, text, length)
        Redcar.event :tab_modified, self unless @was_modified
        Redcar.event :tab_changed
        store_insertion(iter, text, length)
        @was_modified = true
      end
      @buffer.signal_connect("delete_range") do |widget, iter1, iter2|
        Redcar.event :tab_modified, self unless @was_modified
        Redcar.event :tab_changed
        store_deletion(iter1, iter2)
        @was_modified = true
      end
      @no_colouring = false
      @operations = []
    #  $debug_debug_puts = true
    end
    
    def set_theme(th)
      if th
        apply_theme(th)
        @colr = Redcar::Colourer.new(self, th)
        if @parser
          @parser.colourer = @colr
        end
        new_buffer
        colour
      else
        raise StandardError, "nil theme passed to set_theme"
      end
    end
    
    def set_syntax(name)
      set_grammar(Syntax.grammar(:name => name))
    end
    
    def set_grammar(gr)
      if gr
        @grammar = gr
        debug_puts "setting grammar: #{@grammar.name}"
        @scope_tree = Redcar::Syntax::Scope.new(:pattern => gr,
                                                :grammar => gr,
                                                :start => TextLoc.new(0, 0))
        @parser = Redcar::Syntax::Parser.new(@scope_tree, [gr], "", @colr)
      else
        @grammar = nil
        @scope_tree = nil
        @parser = nil
      end
    end
    
    alias :replace_without_syntax :replace
    def replace(text)
      no_colouring do
        replace_without_syntax(text)
      end
      colour
    end
    
    alias :load_without_syntax :load
    def load
      no_colouring do
        load_without_syntax
      end
      if @filename
        ext = File.extname(@filename)
        set_grammar(Syntax.grammar(:extension => ext))
        if syntax?
          debug_puts "setting grammar #{@grammar.name} from file extension: #{ext}"
        end
        colour
      end
    end
    
    def no_colouring
      @no_colouring = true
      yield
      @no_colouring = false
    end
    
    def store_insertion(iter, text, length)
      return if @no_colouring
      iter2 = @buffer.get_iter_at_offset(iter.offset+length)
      insertion = {}
      insertion[:type] = :insertion
      insertion[:from] = TextLoc.new(iter.line,  iter.line_offset)
      insertion[:to]   = TextLoc.new(iter2.line, iter2.line_offset)
      insertion[:text] = text
      insertion[:lines] = text.scan("\n").length+1
      @operations << insertion
      debug_puts "insertion of #{insertion[:lines]} lines from #{insertion[:from]} to #{insertion[:to]}"
      
      Gtk.idle_add do
        unless @operations.empty?
          process_operation(@operations.shift)
        end
        debug_puts "processing an operation"
      end
    end
    
    def store_deletion(iter1, iter2)
      return if @no_colouring
      deletion = {}
      deletion[:type] = :deletion
      deletion[:from] = TextLoc.new(iter1.line, iter1.line_offset)
      deletion[:to]   = TextLoc.new(iter2.line, iter2.line_offset)
      deletion[:lines] = iter2.line-iter1.line+1
      deletion[:length] = iter2.offset-iter1.offset
      
      @operations << deletion
      debug_puts "deletion over #{deletion[:lines]} lines from #{deletion[:from]} to #{deletion[:to]}"
      
      Gtk.idle_add do
        unless @operations.empty?
          process_operation(@operations.shift)
        end
        debug_puts "processing an operation"
      end
    end
    
    def syntax?
      @grammar and @scope_tree and @parser and @colr
    end
    
    def process_operation(operation)
      if syntax?
        case operation[:type]
        when :insertion
          process_insertion(operation)
        when :deletion
          process_deletion(operation)
        end
      end
    end
    
    def num_lines
      @parser.text.length
    end
    
    def process_insertion(insertion)
      if insertion[:lines] == 1
        @parser.insert_in_line(insertion[:from].line, insertion[:text], insertion[:from].offset)
        debug_puts "parsed and coloured line"
      else
        debug_puts "processing insertion of #{insertion[:lines]} lines"
        @parser.insert(insertion[:from], insertion[:text])
      end
    end
    
    def process_deletion(deletion)
      if deletion[:lines] == 1
        @parser.delete_from_line(deletion[:from].line, deletion[:length], deletion[:from].offset)
        debug_puts "parsed and coloured line"
      else
        debug_puts "processing deletion of #{deletion[:lines]} lines"
        @parser.delete_between(deletion[:from], deletion[:to])
      end
    end
    
    def apply_theme(theme)
      background_colour = Theme.parse_colour(theme.global_settings['background'])
      @textview.modify_base(Gtk::STATE_NORMAL, background_colour)
      foreground_colour = Theme.parse_colour(theme.global_settings['foreground'])
      @textview.modify_text(Gtk::STATE_NORMAL, foreground_colour)
      selection_colour  = Theme.parse_colour(theme.global_settings['selection'])
      @textview.modify_base(Gtk::STATE_SELECTED, selection_colour)
    end
    
    def colour
      if syntax?
        #       Thread.new do
        startt = Time.now
        @parser.clear_after(0)
        @buffer.remove_all_tags(iter(start_mark), iter(end_mark))
        @parser.add_lines(self.contents)
        #      debug_puts @scope_tree.pretty
        endt = Time.now
        diff = endt-startt
        puts "time to parse and colour: #{diff}"
        #       end
      end
    end
    
  end
end
