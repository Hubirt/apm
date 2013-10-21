path = require 'path'

async = require 'async'
_ = require 'underscore'
optimist = require 'optimist'
request = require 'request'
temp = require 'temp'
require 'colors'

auth = require './auth'
config = require './config'
Command = require './command'
fs = require './fs'

module.exports =
class Installer extends Command
  @commandNames: ['install']

  constructor: ->
    @atomDirectory = config.getAtomDirectory()
    @atomPackagesDirectory = path.join(@atomDirectory, 'packages')
    @atomNodeDirectory = path.join(@atomDirectory, '.node-gyp')
    @atomNpmPath = require.resolve('npm/bin/npm-cli')
    @atomNodeGypPath = require.resolve('node-gyp/bin/node-gyp')

  parseOptions: (argv) ->
    options = optimist(argv)
    options.usage """

      Usage: apm install [<package_name>]

      Install the given Atom package to ~/.atom/packages/<package_name>.

      If no package name is given then all the dependencies in the package.json
      file are installed into the node_modules folder for the current working
      directory.
    """
    options.alias('h', 'help').describe('help', 'Print this usage message')
    options.alias('d', 'dev').describe('dev', 'Install dev dependencies of atom packages being installed')
    options.boolean('silent').describe('silent', 'Minimize output')

  showHelp: (argv) -> @parseOptions(argv).showHelp()

  installNode: (callback) =>
    process.stdout.write "Installing node@#{config.getNodeVersion()} "

    installNodeArgs = ['install']
    installNodeArgs.push("--target=#{config.getNodeVersion()}")
    installNodeArgs.push("--dist-url=#{config.getNodeUrl()}")
    installNodeArgs.push('--arch=ia32')

    env = _.extend({}, process.env, HOME: @atomNodeDirectory)
    env.USERPROFILE = env.HOME if config.isWin32()

    fs.mkdir(@atomDirectory)
    @fork @atomNodeGypPath, installNodeArgs, {env, cwd: @atomDirectory}, (code, stderr='', stdout='') ->
      if code is 0
        process.stdout.write '\u2713\n'.green
        callback()
      else
        process.stdout.write '\u2717\n'.red
        callback("#{stdout}\n#{stderr}")

  installModule: (options, pack, modulePath, callback) ->
    label = "#{pack.name}@#{pack['dist-tags'].latest}"
    process.stdout.write "Installing #{label} to #{@atomPackagesDirectory} "

    vsArgs = null
    if config.isWin32()
      vsArgs = "--msvs_version=2010" if config.isVs2010Installed()
      vsArgs = "--msvs_version=2012" if config.isVs2012Installed()

      throw new Error("You must have either VS2010 or VS2012 installed") unless vsArgs

    installArgs = ['--userconfig', config.getUserConfigPath(), 'install']
    installArgs.push(modulePath)
    installArgs.push("--target=#{config.getNodeVersion()}")
    installArgs.push('--arch=ia32')
    installArgs.push('--silent') if options.argv.silent
    installArgs.push(vsArgs) if vsArgs?

    env = _.extend({}, process.env, HOME: @atomNodeDirectory)
    env.USERPROFILE = env.HOME if config.isWin32()
    installOptions = {env}

    {installGlobally} = options ? true
    if installGlobally
      installDirectory = temp.mkdirSync('apm-install-dir-')
      nodeModulesDirectory = path.join(installDirectory, 'node_modules')
      fs.mkdir(nodeModulesDirectory)
      installOptions.cwd = installDirectory

    @fork @atomNpmPath, installArgs, installOptions, (code, stderr='', stdout='') =>
      if code is 0
        if installGlobally
          for child in fs.readdirSync(nodeModulesDirectory)
            source = path.join(nodeModulesDirectory, child)
            destination = path.join(@atomPackagesDirectory, child)
            fs.cp(source, destination, forceDelete: true)
          fs.rm(installDirectory)

        process.stdout.write '\u2713\n'.green
        callback()
      else
        fs.rm(installDirectory) if installGlobally

        process.stdout.write '\u2717\n'.red
        callback("#{stdout}\n#{stderr}")

  installModules: (options, callback) =>
    process.stdout.write 'Installing modules '

    @forkInstallCommand options, (code, stderr='', stdout='') =>
      if code is 0
        process.stdout.write '\u2713\n'.green
        callback()
      else
        process.stdout.write '\u2717\n'.red
        callback("#{stdout}\n#{stderr}")

  forkInstallCommand: (options, callback) ->
    installArgs = ['--userconfig', config.getUserConfigPath(), 'install']
    installArgs.push("--target=#{config.getNodeVersion()}")
    installArgs.push('--arch=ia32')
    installArgs.push('--silent') if options.argv.silent
    installArgs.push('--msvs_version=2012') if config.isWin32()
    env = _.extend({}, process.env, HOME: @atomNodeDirectory)
    env.USERPROFILE = env.HOME if config.isWin32()
    installOptions = {env}
    installOptions.cwd = options.cwd if options.cwd

    @fork(@atomNpmPath, installArgs, installOptions, callback)

  # Request package information from the atom.io API for a given package name.
  #
  #  * packageName: The string name of the package to request.
  #  * token: The string authorization token.
  #  * callback: The function to invoke when the request completes with an error
  #    as the first argument and an object as the second.
  requestPackage: (packageName, token, callback) ->
    requestSettings =
      url: "#{config.getAtomPackagesUrl()}/#{packageName}"
      json: true
      headers:
        authorization: token
    request.get requestSettings, (error, response, body={}) ->
      if error?
        callback(error)
      else if response.statusCode isnt 200
        callback("Request for package information failed: #{body}")
      else
        if latestVersion = body['dist-tags'].latest
          callback(null, body)
        else
          callback("No releases available for #{packageName}")

  # Download a package tarball.
  #
  #  * packageUrl: The string tarball URL to request
  #  * token: The string authorization token.
  #  * callback: The function to invoke when the request completes with an error
  #    as the first argument and a string path to the downloaded file as the
  #    second.
  downloadPackage: (packageUrl, token, callback) ->
    requestSettings =
      url: packageUrl
      headers:
        authorization: token
    readStream = request.get(requestSettings)
    readStream.on 'response', (response) ->
      if response.statusCode is 200
        filePath = path.join(temp.mkdirSync(), 'package.tgz')
        writeStream = fs.createWriteStream(filePath)
        readStream.pipe(writeStream)
        writeStream.on 'close', -> callback(null, filePath)
      else
        callback("Unabled to download package URL (#{response.statusCode}): #{packageUrl}")

  # Install the package with the given name and optional version
  #
  #  * metadata: The package metadata object with at least a name key. A version
  #    key is also supported. The version defaults to the latest if unspecified.
  #  * options: The installation options object.
  #  * callback: The function to invoke when installation completes with an
  #    error as the first argument.
  installPackage: (metadata, options, callback) ->
    packageName = metadata.name
    packageVersion = metadata.version

    auth.getToken (error, token) =>
      if error?
        callback(error)
      else
        @requestPackage packageName, token, (error, pack) =>
          if error?
            callback(error)
          else
            commands = []
            packageVersion ?= pack['dist-tags'].latest
            {tarball} = pack.versions[packageVersion]?.dist ? {}
            unless tarball
              callback("Package version: #{packageVersion} not found")
              return

            commands.push (callback) =>
              @downloadPackage(tarball, token, callback)
            commands.push (packagePath, callback) =>
              @installNode (error) -> callback(error, packagePath)
            commands.push (packagePath, callback) =>
              @installModule(options, pack, packagePath, callback)

            async.waterfall(commands, callback)

  installDependencies: (options, callback) ->
    options.installGlobally = false
    commands = []
    commands.push(@installNode)
    commands.push (callback) => @installModules(options, callback)
    for name, version of @getPackageDependencies()
      commands.push (callback) =>
        @installPackage({name, version}, options, callback)
    if options.argv.dev
      commands.push (callback) => @installDevDependencies(options, callback)

    async.waterfall commands, callback

  getPackageDependencies: ->
    try
      metadata = fs.readFileSync('package.json', 'utf8')
      {packageDependencies} = JSON.parse(metadata) ? {}
      packageDependencies ? {}
    catch error
      {}

  isAtomPackageWithDevDependencies: (packagePath) ->
    try
      metadata = fs.readFileSync(path.join(packagePath, 'package.json'), 'utf8')
      {engines, devDependencies} = JSON.parse(metadata) ? {}
      engines?.atom? and devDependencies and Object.keys(devDependencies).length > 0
    catch error
      false

  installDevDependencies: (options, callback) ->
    commands = []
    modulesDirectory = path.resolve('node_modules')
    for child in fs.readdirSync(modulesDirectory)
      packagePath = path.join(modulesDirectory, child)
      continue unless @isAtomPackageWithDevDependencies(packagePath)
      do (child, packagePath) =>
        commands.push (callback) =>
          options.cwd = packagePath
          @forkInstallCommand options, (code, stderr='', stdout='') =>
            if code is 0
              callback()
            else
              callback("#{stdout}\n#{stderr}")

    async.waterfall commands, callback

  createAtomDirectories: ->
    fs.mkdir(@atomDirectory)
    fs.mkdir(@atomPackagesDirectory)
    fs.mkdir(@atomNodeDirectory)

  run: (options) ->
    {callback} = options
    options = @parseOptions(options.commandArgs)

    @createAtomDirectories()
    packageName = options.argv._[0] ? '.'
    if packageName is '.'
      @installDependencies(options, callback)
    else
      @installPackage({name: packageName}, options, callback)
