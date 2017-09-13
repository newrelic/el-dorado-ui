# El Dorado UI

This is a Sinatra app that provides a UI and canned queries for El Dorado.
Learn more about this project at http://ddd.ward.wiki.org/

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

Copyright [2017] New Relic, Inc.  Licensed under the Apache License, version 2.0 (the "License"); you may not use this file except in compliance with the License.  You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0  Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, either express or implied. 