#!/usr/bin/env node

'use strict';

var parser = require('parse-apache-directory-index');
var request = require('request');
var _ = require('lodash');
var program = require('commander');
var spawn = require('child_process').spawn;

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

program
	.usage('[options] <pattern> <url>')
	.option('-u, --user [login]', 'user name for authentication')
	.option('-p, --password [password]', 'password for authentication')
	.option('-s, --scan [interval]', 'scan interval in seconds', 5)
	.option('-r, --refresh [interval]', 'index refresh in seconds', 300)
	.option('-o, --order [order]', 'files order [asc|desc]', 'asc')
	.parse(process.argv);

var filePattern = new RegExp(program.args[0]);
var url = program.args[1];

var urlToWatch = '';
var currentWatcher;

executeIndexRefresh();

setInterval(executeIndexRefresh, program.refresh * 1000);

function executeIndexRefresh() {
	findFileToWatch(function(err, fileToWatch) {
		if(err) {
			print(process.stderr, 'Can not find file to watch. Killing watch process until index is back', err);
			urlToWatch = '';
			restartWatchProcess();
			return;
		}

		if(!fileToWatch) {
			print(process.stderr, 'Unable to find file to watch. Waiting for something to watch');
			urlToWatch = '';
			return;
		}

		var newFileUrl = url + '/' + encodeURIComponent(fileToWatch.name);
		if(newFileUrl !== urlToWatch) {
			print(process.stderr, 'File to watch changed from', urlToWatch, 'to', newFileUrl);
			urlToWatch = newFileUrl;
			restartWatchProcess();
		}
	});
}

function restartWatchProcess() {
	if(currentWatcher) {
		print(process.stderr, 'trying to kill already running process', currentWatcher.pid);
		currentWatcher.kill();
		currentWatcher = null;
	}

	if(urlToWatch === '') {
		return;
	}

	var args = buildTailUrlArgs();
	currentWatcher = spawn('./tailurl.sh', args);
	currentWatcher.stderr.on('data', function (data) {
		print(process.stderr, data.toString());
	});
	currentWatcher.stdout.on('data', function (data) {
		print(process.stdout, _.trim(data.toString()));
	});
}

function buildTailUrlArgs() {
	var result = [];

	if(program.user) {
		result.push('-u');
		result.push(program.user);
	}

	if(program.password) {
		result.push('-p');
		result.push(program.password);
	}

	result.push('-s');
	result.push(program.scan);

	result.push('-f');

	result.push(urlToWatch);

	return result;
}

function findFileToWatch(callback) {
	var requestOptions = {};
	if (program.user && program.password) {
		requestOptions.auth = {
			user: program.user,
			password: program.password,
			sendImmediately: true
		};
	}

	request(url, requestOptions, function (err, response, body) {
		if (err) {
			return callback(err);
		}
		if (hasInvalidResponseStatus(response)) {
			return callback('invalid status code ' + response.statusCode);
		}

		var responseString = body.toString();
		var index = _.chain(parser(responseString).files)
			.filter(function (indexEntry) {
				return filePattern.test(indexEntry.name);
			})
			.sortBy('name')
			.value();

		if (program.order === 'desc') {
			index = _.reverse(index);
		}

		var fileToWatch = _.first(index);
		callback(null, fileToWatch);
	});

	function hasInvalidResponseStatus(response) {
		return response.statusCode < 200 || response.statusCode > 300;
	}
}

function print() {
	var output = arguments[0];
	var args = Array.prototype.slice.call(arguments, 1);
	output.write(_.trim(args.join(' ')) + '\n');
}
