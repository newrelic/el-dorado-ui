# El Dorado UI

This is a Sinatra app that provides a UI and canned queries for El Dorado.

## Running Locally

To get this app running locally:

~~~
gem install bundler
bundle install
bundle exec rackup
~~~

You can then visit the app at http://localhost:9292

We assume the `dot` command is available from [Graphviz](http://www.graphviz.org/).

If you are not running your own instance of Neo4J locally, you'll need to alter
the database connection string with the GRAPHDBURL environment variable.

## License

El Dorado UI is licensed under the __MIT License__.  See [MIT-LICENSE](https://github.com/newrelic/el-dorado-ui/blob/master/MIT-LICENSE) for full text.
