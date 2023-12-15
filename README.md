# Fluentd Docker Stats Input Plugin

This is a [Fluentd](http://www.fluentd.org) plugin to collect Docker stats periodically.
Tested with Fluentd v1.16.2-1.1 and `docker-api` 1.34.2.

## How it works

The script connects to the Docker host using the `docker-api` SDK and periodically queries container statistics. 
It provides insights into the resource usage, health, and other relevant information of the running Docker containers.


## Installing

Make sure you have a Ruby environment. Then initialize this repo:

    gem install bundle

Then:

    bundle install

Alternatively, if you wish to just use the gem in a script, you can run:

    gem install fluent-plugin-docker-stats


## Example config

```
<source>
  @type docker_stats
  stats_interval 60s
  tag docker.stats
</source>
```

## Parameters

* **stats_interval**: how often to poll Docker containers for stats. The default is every minute.
* **tag**: The tag for the input source. The default value is "docker
* **container_ids**: A list of container IDs for reading stats. The default value is empty, which will fetch stats for all containers.

## Example output

```
2023-12-15 09:49:12.530109174 +0000 docker.stats: {"container_id":"e59768d2f1cc8448cc1e609324cdddf70e8e26557bfe307a0887d11ec2132af3","container_name":"mysql","created_time":"2023-07-26T01:39:21.286462238Z","status":"running","is_runn
ing":true,"is_restarting":false,"is_paused":false,"is_oom_killed":false,"started_time":"2023-12-15T00:56:28.701735927Z","finished_time":"2023-12-15T00:56:24.669503934Z","mem_usage":264130560,"mem_limit":33356099584,"mem_max_usage":266227712,"cpu_system_usage":346646650000000,"cpu_total_usage":16206423900,"cpu_percent":0.004675199918995323,"networks":[{"network_name":"eth0","rx":2110,"tx":0}]}
```


