require 'rubygems'
require 'parser/current'
require 'yard'

module Solargraph
  class ApiMap
    KEYWORDS = [
      '__ENCODING__', '__LINE__', '__FILE__', 'BEGIN', 'END', 'alias', 'and',
      'begin', 'break', 'case', 'class', 'def', 'defined?', 'do', 'else',
      'elsif', 'end', 'ensure', 'false', 'for', 'if', 'in', 'module', 'next',
      'nil', 'not', 'or', 'redo', 'rescue', 'retry', 'return', 'self', 'super',
      'then', 'true', 'undef', 'unless', 'until', 'when', 'while', 'yield'
    ]
    
    MAPPABLE_METHODS = [
      :include, :require, :autoload, :attr_reader, :attr_writer, :attr_accessor, :private, :public, :protected
    ]

    include NodeMethods
    
    attr_reader :workspace

    def initialize workspace = nil
      @workspace = workspace
      clear
      unless @workspace.nil?
        files = Dir[File.join workspace, 'lib', '**', '*.rb'] + Dir[File.join workspace, 'app', '**', '*.rb']
        files.each { |f|
          append_file f
        }
      end
    end

    def clear
      @file_nodes = {}
      @file_comments = {}
      @parent_stack = {}
      @namespace_map = {}
      @namespace_tree = {}
      @required = []
    end

    def has_yardoc?
      workspace and File.exist?(File.join(workspace, '.yardoc'))
    end

    def append_file filename
      append_source File.read(filename), filename
    end

    def append_source text, filename = nil
      node, comments = Parser::CurrentRuby.parse_with_comments(text)
      append_node(node, comments, filename)
    end

    def append_node node, comments, filename = nil
      @file_comments[filename] = associate_comments(node, comments)
      mapified = reduce(node, @file_comments[filename])
      root = AST::Node.new(:begin, [filename])
      mapified.children.each { |c|
        root = root.append c
      }
      @file_nodes[filename] = root
      @required.uniq!
      process_maps
    end

    def associate_comments node, comments
      comment_hash = Parser::Source::Comment.associate_locations(node, comments)
      yard_hash = {}
      comment_hash.each_pair { |k, v|
        ctxt = ''
        v.each { |l|
          ctxt += l.text.gsub(/^#/, '') + "\n"
        }
        parser = YARD::DocstringParser.new
        yard_hash[k] = parser.parse(ctxt).to_docstring
      }
      yard_hash
    end

    def get_comment_for node
      filename = get_filename_for(node)
      return nil if @file_comments[filename].nil?
      @file_comments[filename][node.loc]
    end

    def self.get_keywords without_snippets: false
      result = []
      keywords = KEYWORDS
      keywords -= Snippets.keywords if without_snippets
      keywords.each { |k|
        result.push Suggestion.new(k, kind: Suggestion::KEYWORD, detail: 'Keyword')
      }
      result
    end

    def process_maps
      @parent_stack = {}
      @namespace_map = {}
      @namespace_tree = {}
      @file_nodes.values.each { |f|
        map_parents f #AST::Node.new(:tmp, @file_nodes.values)
        map_namespaces f #AST::Node.new(:tmp, @file_nodes.values)
      }
    end
    
    def namespaces
      @namespace_map.keys
    end
    
    def namespace_exists? name, root = ''
      !find_fully_qualified_namespace(name, root).nil?
    end
    
    def namespaces_in name, root = '' #, skip = []
      result = []
      result += inner_namespaces_in(name, root, [])
      yard = YardMap.new(required: @required, workspace: @workspace)
      result += yard.get_constants name, root
      fqns = find_fully_qualified_namespace(name, root)
      unless fqns.nil?
        nodes = get_namespace_nodes(fqns)
        get_include_strings_from(*nodes).each { |i|
          result += yard.get_constants(i, root)
        }
      end
      result
    end
    
    def inner_namespaces_in name, root, skip
      result = []
      fqns = find_fully_qualified_namespace(name, root)
      if fqns.nil?
        return result
      else
        return result if skip.include?(fqns)
        skip.push fqns
        cursor = @namespace_tree
        parts = fqns.split('::')
        parts.each { |p|
          cursor = cursor[p]
        }
        unless cursor.nil?
          cursor.keys.each { |k|
            type = get_namespace_type(k, fqns)
            kind = nil
            detail = nil
            if type == :class
              kind = Suggestion::CLASS
              detail = 'Class'
            elsif type == :module
              kind = Suggestion::MODULE
              detail = 'Module'
            end
            result.push Suggestion.new(k, kind: kind, detail: detail)
          }
          nodes = get_namespace_nodes(fqns)
          nodes.each { |n|
            get_include_strings_from(n).each { |i|
              result += inner_namespaces_in(i, fqns, skip)
            }
          }
        end
      end
      result
    end

    def find_fully_qualified_namespace name, root = '', skip = []
      return nil if skip.include?(root)
      skip.push root
      if name == ''
        if root == ''
          return ''
        else
          return find_fully_qualified_namespace(root, '', skip)
        end
      else
        if (root == '')
          return name unless @namespace_map[name].nil?
          get_include_strings_from(*@file_nodes.values).each { |i|
            reroot = "#{root == '' ? '' : root + '::'}#{i}"
            recname = find_fully_qualified_namespace name, reroot, skip
            return recname unless recname.nil?
          }
        else
          roots = root.to_s.split('::')
          while roots.length > 0
            fqns = roots.join('::') + '::' + name
            return fqns unless @namespace_map[fqns].nil?
            roots.pop
          end
          return name unless @namespace_map[name].nil?
          get_include_strings_from(*@file_nodes.values).each { |i|
            recname = find_fully_qualified_namespace name, i, skip
            return recname unless recname.nil?
          }
        end
      end
      nil
    end

    def get_namespace_nodes(fqns)
      return @file_nodes.values if fqns == ''
      @namespace_map[fqns] || []
    end
    
    def get_instance_variables(namespace, scope = :instance)
      nodes = get_namespace_nodes(namespace) || @file_nodes.values
      arr = []
      nodes.each { |n|
        arr += inner_get_instance_variables(n, scope)
      }
      arr
    end
    
    def find_parent(node, *types)
      parents = @parent_stack[node]
      parents.each { |p|
        return p if types.include?(p.type)
      }
      nil
    end
    
    def get_root_for(node)
      @parent_stack[node].last unless @parent_stack[node].nil?
    end

    def get_filename_for(node)
      root = get_root_for(node)
      root.children[0]
    end

    def inner_get_instance_variables(node, scope)
      arr = []
      if node.kind_of?(AST::Node)
        node.children.each { |c|
          if c.kind_of?(AST::Node)
            is_inst = !find_parent(c, :def).nil?
            if c.type == :ivasgn and ( (scope == :instance and is_inst) or (scope != :instance and !is_inst) )
              arr.push Suggestion.new(c.children[0], kind: Suggestion::VARIABLE)
            end
            arr += inner_get_instance_variables(c, scope) unless [:class, :module].include?(c.type)
          end
        }
      end
      arr
    end

    def infer_instance_variable(var, namespace, scope = :instance)
      vn = nil
      if namespace_exists?(namespace)
        get_namespace_nodes(namespace).each { |node|
          vn = find_instance_variable_assignment(var, node, scope)
          break unless vn.nil?
        }
      end
      infer(vn.children[1]) unless vn.nil?
    end

    def find_instance_variable_assignment(var, node, scope)
      node.children.each { |c|
        if c.kind_of?(AST::Node)
          is_inst = !find_parent(c, :def).nil?
          if c.type == :ivasgn and ( (scope == :instance and is_inst) or (scope != :instance and !is_inst) )
            if c.children[0].to_s == var
              return c
            end
          else
            inner = find_instance_variable_assignment(var, c, scope)
            return inner unless inner.nil?
          end
        end
      }
      nil
    end
    
    def get_global_variables
      # TODO: Get them
      []
    end
    
    def get_namespace_type namespace, root = ''
      type = nil
      fqns = find_fully_qualified_namespace(namespace, root)
      nodes = get_namespace_nodes(fqns)
      unless nodes.nil? or nodes.empty? or !nodes[0].kind_of?(AST::Node)
        type = nodes[0].type if [:class, :module].include?(nodes[0].type)
      end
      type
    end

    def get_methods(namespace, root = '')
      meths = []
      meths += inner_get_methods(namespace, root, []) #unless has_yardoc?
      yard = YardMap.new(required: @required, workspace: @workspace)
      meths += yard.get_methods(namespace, root)
      type = get_namespace_type(namespace, root)
      if type == :class
        meths += yard.get_instance_methods('Class')
      elsif type == :module
        meths += yard.get_methods('Module')
      end
      meths
    end
    
    def get_method_args node
      list = nil
      args = []
      node.children.each { |c|
        if c.kind_of?(AST::Node) and c.type == :args
          list = c
          break
        end
      }
      return args if list.nil?
      list.children.each { |c|
        if c.type == :arg
          args.push c.children[0]
        end
      }
      args
    end

    def get_instance_methods(namespace, root = '')
      meths = []
      meths += inner_get_instance_methods(namespace, root, []) #unless has_yardoc?
      yard = YardMap.new(required: @required, workspace: @workspace)
      yard_meths = yard.get_instance_methods(namespace, root)
      if yard_meths.any?
        meths.concat yard_meths
      else
        type = get_namespace_type(namespace, root)
        if type == :class
          meths += yard.get_instance_methods('Object')
        elsif type == :module
          meths += yard.get_instance_methods('Module')
        end
        # TODO: Look out for repeats. Consider not doing this at all.
        sc = get_superclass(namespace, root)
        until sc.nil?
          meths += yard.get_instance_methods(sc, root)
          sc = get_superclass(sc)
        end
      end
      meths
    end

    def get_superclass(namespace, root = '')
      fqns = find_fully_qualified_namespace(namespace, root)
      nodes = get_namespace_nodes(fqns)
      nodes.each { |n|
        if n.kind_of?(AST::Node)
          if n.type == :class and !n.children[1].nil?
            return unpack_name(n.children[1])
          end
        end
      }
      return nil
    end
    
    def self.current
      if @current.nil?
        @current = ApiMap.new
        @current.merge(Parser::CurrentRuby.parse(File.read("#{Solargraph::STUB_PATH}/ruby/2.3.0/core.rb")))
      end
      @current
    end
    
    def get_include_strings_from *nodes
      arr = []
      nodes.each { |node|
        next unless node.kind_of?(AST::Node)
        arr.push unpack_name(node.children[2]) if (node.type == :send and node.children[1] == :include)
        node.children.each { |n|
          arr += get_include_strings_from(n) if n.kind_of?(AST::Node) and n.type != :class and n.type != :module
        }
      }
      arr
    end
    
    private

    def inner_get_methods(namespace, root = '', skip = [])
      meths = []
      return meths if skip.include?(namespace)
      skip.push namespace
      fqns = find_fully_qualified_namespace(namespace, root)
      return meths if fqns.nil?
      nodes = get_namespace_nodes(fqns)
      nodes.each { |n|
        if n.kind_of?(AST::Node)
          if n.type == :class and !n.children[1].nil?
            s = unpack_name(n.children[1])
            meths += inner_get_methods(s, root, skip)
          end
          n.children.each { |c|
            if c.kind_of?(AST::Node) and c.type == :defs
              docstring = get_comment_for(c)
              label = "#{c.children[1]}"
              args = get_method_args(c)
              label += " #{args.join(', ')}" unless args.empty?
              meths.push Suggestion.new(label, insert: c.children[1].to_s, kind: Suggestion::METHOD, detail: 'Method', documentation: docstring) if c.children[1].to_s[0].match(/[a-z_]/i) and c.children[1] != :def
            elsif c.kind_of?(AST::Node) and c.type == :send and c.children[1] == :include
              # TODO: This might not be right. Should we be getting singleton methods
              # from an include, or only from an extend?
              i = unpack_name(c.children[2])
              meths += inner_get_methods(i, root, skip) unless i == 'Kernel'
            end
          }
        end
      }
      meths.uniq
    end

    def inner_get_instance_methods(namespace, root, skip)
      fqns = find_fully_qualified_namespace(namespace, root)
      meths = []
      return meths if skip.include?(fqns)
      skip.push fqns
      nodes = get_namespace_nodes(fqns)
      nodes.each { |n|
        if n.kind_of?(AST::Node)
          if n.type == :class and !n.children[1].nil?
            s = unpack_name(n.children[1])
            meths += inner_get_instance_methods(s, namespace, skip)
          end
          current_scope = :public
          n.children.each { |c|
            if c.kind_of?(AST::Node) and c.type == :send and [:public, :protected, :private].include?(c.children[1])
            # TODO: Determine the current scope so we can decide whether to
            # exclude protected or private methods. Right now we're just
            # assuming public only
            elsif current_scope == :public
              if c.kind_of?(AST::Node) and c.type == :def
                cmnt = get_comment_for(c)
                label = "#{c.children[0]}"
                args = get_method_args(c)
                label += " #{args.join(', ')}" unless args.empty?
                meths.push Suggestion.new(label, insert: c.children[0].to_s, kind: Suggestion::METHOD, documentation: cmnt, detail: fqns) if c.children[0].to_s[0].match(/[a-z]/i)
              elsif c.kind_of?(AST::Node) and c.type == :send and c.children[1] == :attr_reader
                c.children[2..-1].each { |x|
                  meths.push Suggestion.new(x.children[0], kind: Suggestion::METHOD) if x.type == :sym
                }
              elsif c.kind_of?(AST::Node) and c.type == :send and c.children[1] == :attr_writer
                c.children[2..-1].each { |x|
                  meths.push Suggestion.new("#{x.children[0]}=", kind: Suggestion::METHOD) if x.type == :sym
                }
              elsif c.kind_of?(AST::Node) and c.type == :send and c.children[1] == :attr_accessor
                c.children[2..-1].each { |x|
                  meths.push Suggestion.new(x.children[0], kind: Suggestion::METHOD) if x.type == :sym
                  meths.push Suggestion.new("#{x.children[0]}=", kind: Suggestion::METHOD) if x.type == :sym
                }
              end
            end
            get_include_strings_from(n).each { |i|
              meths += inner_get_instance_methods(i, fqns, skip)
            }
          }
        end
      }
      meths.uniq
    end

    def mappable?(node)
      # TODO Add node.type :casgn (constant assignment)
      if node.kind_of?(AST::Node) and (node.type == :class or node.type == :module or node.type == :def or node.type == :defs or node.type == :ivasgn or node.type == :gvasgn or node.type == :or_asgn)
        true
      elsif node.kind_of?(AST::Node) and node.type == :send and node.children[0] == nil and MAPPABLE_METHODS.include?(node.children[1])
        true
      else
        false
      end
    end
    
    def reduce node, comment_hash
      mappable = get_mappable_nodes(node.children, comment_hash)
      result = node.updated nil, mappable
      result
    end
    
    def get_mappable_nodes arr, comment_hash
      result = []
      arr.each { |n|
        if mappable?(n)
          min = minify(n, comment_hash)
          result.push min
        else
          next unless n.kind_of?(AST::Node)
          result += get_mappable_nodes(n.children, comment_hash)
        end
      }
      result
    end
    
    def minify node, comment_hash
      return node if node.type == :args
      type = node.type
      children = []
      if node.type == :class
        children += node.children[0, 2]
        children += get_mappable_nodes(node.children[2..-1], comment_hash)
      elsif node.type == :def
        children += node.children[0, 2]
        children += get_mappable_nodes(node.children[2..-1], comment_hash)
      elsif node.type == :defs
        children += node.children[0, 3]
        children += get_mappable_nodes(node.children[3..-1], comment_hash)
      elsif node.type == :module
        children += node.children[0, 1]
        children += get_mappable_nodes(node.children[1..-1], comment_hash)
      elsif node.type == :ivasgn or node.type == :gvasgn
        children += node.children
      elsif node.type == :send and node.children[1] == :include
        children += node.children[0,3]
      elsif node.type == :send and node.children[1] == :require
        @required.push(node.children[2].children[0])
        children += node.children[0, 3]
      elsif node.type == :send and node.children[1] == :autoload
        @required.push(node.children[3].children[0])
        type = :require
        children += node.children[1, 3]
      elsif node.type == :send
        children += node.children
      elsif node.type == :or_asgn
        # TODO: The api_map should ignore local variables.
        type = node.children[0].type
        children.push node.children[0].children[0], node.children[1]
      end
      result = node.updated(type, children)
      result
    end
    
    def map_parents node, tree = []
      if node.kind_of?(AST::Node)
        @parent_stack[node] = tree
        node.children.each { |c|
          map_parents c, [node] + tree
        }
      end
    end
    
    def add_to_namespace_tree tree
      cursor = @namespace_tree
      tree.each { |t|
        cursor[t.to_s] ||= {}
        cursor = cursor[t.to_s]
      }
    end
    
    def map_namespaces node, tree = []
      if node.kind_of?(AST::Node)
        if node.type == :class or node.type == :module
          if node.children[0].children[0].kind_of?(AST::Node) and node.children[0].children[0].type == :cbase
            tree = pack_name(node.children[0])
          else
            tree = tree + pack_name(node.children[0])
          end
          add_to_namespace_tree tree
          fqn = tree.join('::')
          @namespace_map[fqn] ||= []
          @namespace_map[fqn].push node
        end
        node.children.each { |c|
          map_namespaces c, tree
        }
      end
    end    
  end
end
