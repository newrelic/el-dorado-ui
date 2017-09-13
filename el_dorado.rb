# Copyright 2017 New Relic, Inc.  Licensed under the Apache License, version 2.0 (the "License");you may not use this
# file except in compliance with the License.  You may obtain a copy of the License at http://www.apache.org/licenses/
# LICENSE-2.0  Unless required by applicable law or agreed to in writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, either express or implied. require 'open3'

require 'open3'

class ElDorado < Sinatra::Base

  configure :development do
    register Sinatra::Reloader
  end

  get '/' do
    haml :welcome
  end

  get '/catalog' do
    haml :catalog
  end

  get '/about' do
    haml :about
  end

  get '/label_name_detail' do
    query = queries['label_name_detail']
    query['alias'] = {'Name' => params['label'].downcase }
    run 'label_name_detail', query
    haml :query
  end

  get '/find' do
    comp = params['comp']||''
    params['regex'] = comp.downcase.gsub(/^|$| /, '.*')
    params['regex'] += "|#{comp.downcase.split('').join('.*[ _-]')}.*" if comp =~ /^[A-Z]+$/
    run 'find'
    haml :query
  end

  get '/run' do
    tip = 'Ad hoc query and graph. With power comes responsibility.
      See docs [https://neo4j.com/docs/cypher-refcard/current/ cypher],
      [http://www.graphviz.org/content/dot-language dot]'
    query = deyamlify(params['query']).merge({'title' => 'Run Query', 'description' => tip})
    run 'run', query
    dotplot query
    haml :query
  end

  get '/download' do
    query = deyamlify(params['query']).merge({'title' => 'Run Query'})
    run 'run', query
    content_type :json
    JSON.pretty_generate decypher @results
  end

  get '/smoketest' do
    @report = []
    count = 0
    queries.each do |slug, query|
      count += 1
      if inputs(query).length == 0 || !query['args'].nil?
        start = Time.now
        run slug, query, query['args']||{}
        # run slug, query
        duration = Time.now - start
        errors = @error ||
          (slug=='errors' ? @results.count!=0 && 'found' : @results.count==0 && 'no rows') ||
          (slug!='errors' && has_empty_column? && 'empty column') ||
          duration>1.5 && 'slow' ||
          ''
        @report << {
          slug: slug,
          query: query,
          duration: duration,
          rows: @results.count,
          columns: @columns,
          error: errors
        }
      else
        @report << {
          slug: slug,
          query: query,
          error: 'missing sample args'
        }
      end
      # break if count > 3
    end
    haml :smoketest
  end

  get '/:query' do |slug|
    if queries[slug]
      run slug
      dotplot queries[slug]
    else
      body "<center><h1>404: query not found</h1>See <a href=/catalog>Catalog</a>"
      halt 404
    end
    haml :query
  end

  get '/download/:query' do |slug|
    if queries[slug]
      run slug
    else
      body "404: query not found"
      halt 404
    end
    content_type :json
    JSON.pretty_generate decypher @results
  end


  helpers do

    def yamldef query, field
      return '' unless query[field]
      "#{field}: |\n" +
      query[field].split(/\n/).map{|line|"  #{line}\n"}.join('')
    end

    def yamlify query
      yamldef(query, 'query') +
      yamldef(query, 'dot')
    end

    def deyamlify string
      if string.split("\n")[0] == 'query: |'
        YAML.load(string)
      else
        {'query' => string}
      end
    end

    def decypher results
      results.to_a.map do |struct|
        decypher_row struct.to_h
      end
    end

    def decypher_row elem
      case elem
      when Hash then elem.inject({}) {|hash,(key, value)| hash[key] = decypher_row(value); hash}
      when Array then elem.map {|value| decypher_row(value)}
      when Neo4j::Server::CypherNode then elem.props
      when Neo4j::Server::CypherRelationship then elem.props
      else elem
      end
    end

    def quote string
      "\"#{string.gsub(/[ _-]+/,'\n')}\""
    end

    def dotsub buffer, key, value
      buffer
        .gsub("\"{#{key}}\"",quote(value))
        .gsub("{#{key}}",value.gsub("&", "-aMp-"))
    end

    def interpolate_kv(buffer, key, val)
      if val.is_a? Array
        return val.map do |elem|
          interpolate_kv(buffer, key, elem)
        end.join("\n")
      elsif val.is_a? Hash
        val.each do |subkey,subval|
          buffer = interpolate_kv(buffer, "#{key}.#{subkey}", subval)
        end
        return buffer
      else
        return dotsub(buffer, key, val.to_s)
      end
    end

    def add_base_to_urls(template)
      template.gsub(/URL="/, %(URL="#{request.base_url}))
    end

    def dotify template
      columns = @results.first.members
      output = []
      add_base_to_urls(template).lines.each do |line|
        line = line.gsub(/&/, '&amp;') # http://www.graphviz.org/doc/info/lang.html
        if (keywords = columns.select {|key| line.include? "{#{key}}"}).any?
          @results.each do |row|
            next unless keywords.all? {|key| row[key]}
            buffer = line.dup
            keywords.each do |key|
              buffer = interpolate_kv(buffer, key, row[key])
            end
            output << buffer
          end
        else
          output << line
        end
      end
      output.join("\n")
    end

    def dotplot query
      if @results.any? && (dot = query['dot'])
        @svg = pipe('dot -Tsvg', dotify(dot))
          .gsub(/<a /,'<a target="_top" ')
      end
    end

    def has_empty_column?
      @columns.each_with_index do |value, col|
        return true unless @results.map{|row|row[col]}.any?
      end
      false
    end

    def inputs(query)
      query['query'].scan(/\{([a-z]+)\}/).flatten.sort.uniq
    end

    def outputs(query)
      query['query'].scan(/as (\w+)\b/).flatten.map{|key|label(query,key)}.sort.uniq
    end

    def label(query, col)
      if @query['alias'] && @query['alias'][col.to_s]
        @query['alias'][col.to_s].downcase
      else
        col.to_s.downcase
      end
    end

    def json text
      JSON.parse text
    rescue JSON::ParserError => e
      nil
    end

    def run slug, query=nil, args=nil
      @query = query || queries[slug]
      @error = nil

      # Prepare required URL params
      @params = (args||params).select{ |k,_| inputs(@query).include? k }
      @params.each{|k,v| @params[k] = v.sub(/-aMp-/,'&')}
      # Run the query
      begin
        @results = neo4j.query(@query['query'], @params)
      rescue Exception => e
        @results = []
        @error = e.message
      end

      # Select targets for clicks by column
      if @results.first
        @columns = @results.first.members
        @targets = find_best_target slug
      else
        @columns = []
      end
    end

    def sample_args(query)
      URI.encode_www_form query['args']||[]
    end

    def formatted_value(value, column, row=nil)
      if value.nil?
        ''
      elsif value.kind_of? Array
        value.map{|v| formatted_value(v, column, row)}.join("<br/>")
      elsif value.kind_of? String and value[0]=='[' and json(value)
        formatted_value json(value), column
      elsif value.kind_of? String and value.match(/^https?:/)
        link_to_url(value)
      elsif value.kind_of? Hash
        preserve("<pre>#{value.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif value.kind_of? Neo4j::Server::CypherNode
        # http://www.rubydoc.info/github/neo4jrb/neo4j-core/Neo4j/Server/CypherNode
        preserve("<pre>#{value.props.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif value.kind_of? Neo4j::Server::CypherRelationship
        # http://www.rubydoc.info/github/neo4jrb/neo4j-core/Neo4j/Server/CypherNode
        preserve("<pre>#{value.props.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif @targets && !(@targets[column].nil? || @targets[column].empty?)
        link_to_targets(value, label(@query,column), @targets[column].keys.first)
      elsif column == :Node && !row.nil? && @columns.include?(:Label)
        link_to_label_detail(value, row[:Label])
      else
        value
      end
    end

    def link_to_url(value)
      kind = case value
      when /README/ then 'readme'
      when /docs.google.com/ then 'docs'
      when /\/wiki\// then 'wiki'
      when /\.md/ then 'doc'
      else 'site'
      end
      "<a href=\"#{value}\" target=_blank>#{kind}</a>"
    end

    def link_to_targets(value, label, target)
      %Q|<a href="/#{target}?#{label.downcase}=#{enc value}">#{value}</a>|
    end

    def link_to_label_detail(value, label)
      %Q|<a href="/label_name_detail?label=#{enc label.upcase}&name=#{enc value}">#{value}</a>|
    end

    def find_best_target slug
      places = queries.keys
      here = places.index slug
      forward = places.rotate here||0
      @columns.inject({}) do |res, col|
        want = label(@query,col)
        there = forward.index { |key| q = inputs(queries[key]); q.size == 1 and q.first == want }
        if there
          slug_there = forward[there]
          targets = {slug_there => queries[slug_there]}
          res.update(col => targets)
        else
          res
        end
      end
    end

    def recommended
      if want = @params['type'] || @params['label']
        count = 0
        queries.each do |slug, query|
          if query['query'].match /:#{want}\b/ and inputs(query).empty?
            yield slug, query
            count += 1
          end
        break if count >= 3
        end
      end
    end

    def yaml
      @yaml ||= YAML.load_file('config/queries.yml')
    end

    def queries
      @queries ||= yaml.select{ |s,q| q['query']}
    end

    def neo4j
      @neo4j ||= Neo4j::Session.open(:server_db, ENV['GRAPHDBURL']||'http://neo4j:password@localhost:7474/')
    end

    def pipe cmd, input
      result = nil
      Open3.popen3(cmd) do |i, o, e, t|
        i.write input
        i.close
        result = o.read
      end
      result
    end

    def enc(thing)
      return "" if thing.nil?
      return thing.collect { |c| URI.encode(c) } if thing.kind_of?(Array)
      CGI.escape(thing.to_s)
    end
  end
end
