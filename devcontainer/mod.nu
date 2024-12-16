export-env {
    $env.DEVCONTAINER_PRESET = [
        {
            type: fastapi
            manifest: requirements.txt
            base: "python:3.11-bookworm"
            workdir: /app
            env: {
                PYTHONUNBUFFERED: x
            },
            scripts: [
                "pip config --global set global.index-url http://nexus.s/repository/pypi/simple"
                "pip config --global set global.trusted-host nexus.s"
                "pip install --break-system-packages --no-cache-dir -r requirements.txt"
            ],
            cmd: [fastapi run main.py]
        }
        {
            type: php
            manifest: composer.json
            base: "ghcr.lizzie.fun/fj0r/0x:php7"
            scripts: [
                "composer config -g repo.packagist composer http://nexus.s/repository/composer/"
                "composer config -g disable-tls true"
                "composer config -g secure-http false"
                "composer install"
                "mv vendor /opt"
                "ln -s /opt/vendor vendor"
            ]
            workdir: /srv
        }
        {
            type: node
            manifest: package.json
            base: "node:lts-slim"
            workdir: /app
            env: {
                LANG: "C.UTF-8"
                LC_ALL: "C.UTF-8"
                TIMEZONE: Asia/Shanghai
            }
            scripts: [
                #"export http_proxy=http://172.178.1.111:7890"
                #"export https_proxy=http://172.178.1.111:7890"
                #"npm config set registry https://registry.npmjs.org"
                "npm config set registry http://nexus.s/repository/npm/"
                "npm i"
                "mv node_modules /opt"
                "ln -s /opt/node_modules node_modules"
            ]
        }
        {
            type: npm-lock
            manifest: package-lock.json
            base: "node:lts-slim"
            workdir: /app
            env: {
                LANG: "C.UTF-8"
                LC_ALL: "C.UTF-8"
                TIMEZONE: Asia/Shanghai
            }
            scripts: [
                "npm config set registry http://nexus.s/repository/npm/"
                "sed -i 's/^\\s*\"resolved\"\\s*:.*$//g' package-lock.json"
                "npm i"
                "mv node_modules /opt"
                "ln -s /opt/node_modules node_modules"
            ]
        }
    ]
}


export def "image created" [
    url: string
    repo: string
    tag: string
] {
    let header = if ($env.REGISTRY_TOKEN? | is-not-empty) {
        { "Authorization": $"Basic ($env.REGISTRY_TOKEN)" }
    } else {
        {}
    }
    | merge { 'Accept': 'application/vnd.oci.image.manifest.v1+json' }

    let header = $header | items {|k, v| [-H $"($k): ($v)"]} | flatten

    let d = curl -sSL ...$header $"($url)/v2/($repo)/manifests/($tag)" | from json
    let d = do -i { $d.config.digest }
    if ($d | is-empty)  {
        return
    }

    curl -sSL ...$header $"($url)/v2/($repo)/blobs/($d)"
    | from json
    | get created
    | into datetime
}

export def "file modified" [file] {
    git log -1 --pretty="format:%ci" $file | into datetime
}

def gen-line [] {
    $in
    | each {|x|
        let p = if ($x | str trim -l | str starts-with "|") { "  " } else { '; ' }
        $"  ($p)($x) \\"
    }
}

def 'plan base' [
    conf: record
    context: record
] {
    let f = [
        $"FROM ($conf.base)"
        ...(if ($conf.env? | is-empty) {[]} else { $conf.env | items {|k, v| $"ENV ($k)=($v)" } })
        $""
        $"WORKDIR ($conf.workdir)"
        $"COPY ($conf.manifest) ."
        $"RUN set -eux \\"
        ...(if ($context.proxy? | is-empty) {
            []
        } else {
            $context.proxy | each {|x| [$"export http_proxy=($x)" $"export https_proxy=($x)"] } | flatten | gen-line
        })
        ...(if ($conf.setup? | is-empty) {[]} else { $conf.setup | gen-line })
        ...($conf.scripts | gen-line)
        $"  ;"
        ...(if ($conf.cmd? | is-empty) {[]} else {[$"" $"CMD ($conf.cmd | to json -r)"]})
    ] | str join (char newline)
    {
        dockerfile: $f
        ctx: $context.ctx
        tag: $"($context.reg)/($context.repo):($context.tag)"
    }
}

def 'plan proj' [
    reg: string
    repo: string
    tag
    baseimg: string
    dockerfile: string
    ctx
    args
] {
    let n = date now | format date "%Y-%m-%d %H:%M:%S"
    let t = git log --reverse -n 1 --pretty=%h»¦«%s | split row '»¦«'
    let dockerfile = open $dockerfile | inject env
    let dockerfile = [
        'ARG BASE_IMAGE'
        $dockerfile
    ] | str join (char newline)
    {
        dockerfile: $dockerfile
        ctx: $ctx
        tag: $"($reg)/($repo):($tag)"
        args: {
            CI_PIPELINE_CREATED: $n
            CI_COMMIT_TITLE: $t.1
            CI_COMMIT_SHA: $t.0
            BASE_IMAGE: $baseimg
        }
    }
}

def 'inject env' [] {
    mut f = $in | lines
    for i in (($f | length) - 1)..0 {
        if ($f | get $i | str trim -l | str starts-with 'FROM') {
            let new = [
                ($f | get $i)
                'ARG CI_PIPELINE_CREATED'
                'ARG CI_COMMIT_TITLE'
                'ARG CI_COMMIT_SHA'
                'ENV CI_PIPELINE_CREATED=${CI_PIPELINE_CREATED}'
                'ENV CI_COMMIT_TITLE=${CI_COMMIT_TITLE}'
                'ENV CI_COMMIT_SHA=${CI_COMMIT_SHA}'
            ] | str join (char newline)
            return ($f | update $i $new | str join (char newline))
        }
    }
}

def 'build plan' [--rm --latest] {
    let plan = $in
    let args = $plan.args?
    | default {}
    | items {|k, v|
        let arg = if ($v | str contains ' ') { $"($k)='($v)'" } else { $"($k)=($v)" }
        ["--build-arg" $arg]
    }
    | flatten

    $plan.dockerfile | ^$env.CONTCTL build ...$args -f - -t $plan.tag $plan.ctx
    ^$env.CONTCTL push $plan.tag

    if $latest {
        let latest = $plan.tag | split row ':' | range 0..<-1 | append 'latest' | str join ':'
        ^$env.CONTCTL tag $plan.tag $latest
        ^$env.CONTCTL push $latest
        if $rm {
            ^$env.CONTCTL rmi $latest
        }
    }

    if $rm {
        ^$env.CONTCTL rmi $plan.tag
    }
}


def 'merge config' [type] {
    let preset = [$env.FILE_PWD preset.yml] | path join
    let g = $env.DEVCONTAINER_PRESET
    | append (if ($preset | path exists) { open $preset } else { [] })

    let p = if ('proj.yml' | path exists) {
        open 'proj.yml'
    } else {
        {}
    }

    let c = $g
    | where type == if ($p.type? | is-not-empty) { $p.type } else { $type }
    | first

    let x = {
        env: {...($c.env? | default {}), ...($p.env? | default {})}
        scripts: [...($c.scripts? | default []), ...($p.scripts? | default [])]
    }
    $c | merge $p | merge $x
}

export def 'main' [type? --dry-run --example] {
    let o = $in
    if $example {
        [
            $"$env.CONTCTL = 'podman'"
            $"cd <project>"
            ({
                registry: registry.s
                image: "data/openai-be:240823153043"
                context: .
                args: {
                    CI_PIPELINE_BEGIN: "2024-08-23T15:30:43+08:00"
                    CI_PIPELINE_ID: "ci--dgj7t"
                    CI_COMMIT_TITLE: ""
                    CI_COMMIT_SHA: "4be2cbf66996f8d67de8bd43ae8c94188e6dc938"
                }
            } | to nuon -i 4)
            $'| to json -r'
            $'| nu --stdin ../mod.nu requirement.txt --dry-run'
        ]
        | str join (char newline)
        | print $"(ansi grey)($in)(ansi reset)"

        return
    }
    let o = $o | from json
    let i = $o.image | split row ':'
    let o = {
        reg: $o.registry
        repo: $i.0
        tag: $i.1
        ctx: $o.context
        args: $o.args
        proxy: $o.proxy?
    }

    let conf = merge config $type
    const base_tag = '__'

    let manifest = $conf.manifest
    if ($manifest | path exists | not $in) {
        print $"($manifest) not exists"
        return
    }


    let baseimg_date = image created $"http://($o.reg)" $o.repo $base_tag
    let manifest_date = file modified $manifest
    $env.config.table.mode = 'compact'
    $env.config.table.padding = 0
    $env.config.datetime_format.normal = '%m/%d/%y %H:%M:%S'
    if ($baseimg_date | is-not-empty) {
        print $"($manifest): ($manifest_date), baseimage: ($baseimg_date)"
        print $"($manifest) newer than baseimage: ($manifest_date - $baseimg_date)"
    }
    if ($baseimg_date | is-empty) or ($baseimg_date < $manifest_date) or $dry_run {
        let planb = plan base $conf ($o | upsert tag $base_tag)
        print ($planb | table -e)
        if not $dry_run {
            $planb | build plan
        }
    }
    let baseimg = $"($o.reg)/($o.repo):($base_tag)"
    let planp = plan proj $o.reg $o.repo $o.tag $baseimg ($o.dockerfile? | default 'Dockerfile') $o.ctx $o.args
    print ($planp | table -e)
    if not $dry_run {
        $planp | build plan --latest --rm
    }
}
