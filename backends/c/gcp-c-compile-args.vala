/*
 * This file is part of gedit-code-assistant.
 *
 * Copyright (C) 2011 - Jesse van den Kieboom
 *
 * gedit-code-assistant is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * gedit-code-assistant is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with gedit-code-assistant.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

namespace Gcp.C
{
	public errordomain CompileArgsError
	{
		MISSING_MAKEFILE,
		MISSING_TARGET,
		MISSING_MAKE_OUTPUT
	}

	class CompileArgs : Object
	{
		private class Cache
		{
			private File d_source;
			private File? d_makefile;
			private string[] d_args;

			public Cache(File source, File? makefile, string[] args)
			{
				d_source = source;
				d_makefile = makefile;
				d_args = args;
			}

			public File makefile
			{
				get
				{
					return d_makefile;
				}
			}

			public File source
			{
				get
				{
					return d_source;
				}
			}

			public string[] args
			{
				get
				{
					return d_args;
				}
				set
				{
					d_args = value;
				}
			}
		}

		private class Makefile
		{
			private File d_file;
			private ArrayList<File> d_sources;
			private FileMonitor ?d_monitor;
			private uint d_timeoutid;

			public signal void changed();

			public Makefile(File file)
			{
				d_file = file;
				d_timeoutid = 0;
				d_monitor = null;

				try
				{
					d_monitor = file.monitor(FileMonitorFlags.NONE);
				}
				catch (Error error)
				{
					return;
				}

				d_sources = new ArrayList<File>();

				d_monitor.changed.connect(on_makefile_changed);
			}

			public bool valid
			{
				get
				{
					return d_monitor != null;
				}
			}

			public void add(File source)
			{
				d_sources.add(source);
			}

			public bool remove(File source)
			{
				d_sources.remove(source);

				return (d_sources.size == 0);
			}

			public ArrayList<File> sources
			{
				get
				{
					return d_sources;
				}
			}

			public File file
			{
				get
				{
					return d_file;
				}
			}

			private void on_makefile_changed(File file, File ?other, FileMonitorEvent event_type)
			{
				if (event_type == FileMonitorEvent.CHANGED ||
				    event_type == FileMonitorEvent.CREATED)
				{
					if (d_timeoutid != 0)
					{
						Source.remove(d_timeoutid);
					}

					d_timeoutid = Timeout.add(100, on_makefile_timeout);
				}
			}

			private bool on_makefile_timeout()
			{
				d_timeoutid = 0;

				changed();

				return false;
			}
			
		}

		private HashMap<File, Cache> d_argsCache;
		private HashMap<File, Makefile> d_makefileCache;

		public signal void arguments_changed(File file);

		construct
		{
			d_argsCache = new HashMap<File, Cache>(File.hash, (EqualFunc)File.equal);
			d_makefileCache = new HashMap<File, Makefile>(File.hash, (EqualFunc)File.equal);
		}

		private File ?makefile_for(File file,
		                           Cancellable ?cancellable = null) throws IOError,
		                                                                   Error
		{
			File ?ret = null;

			File? par = file.get_parent();

			while (par != null && ret == null)
			{
				File makefile = par.get_child("Makefile");

				if (makefile.query_exists(cancellable))
				{
					ret = makefile;
				}

				par = par.get_parent();
			}

			if (ret != null)
			{
				Log.debug("Resolved makefile for `%s': `%s'",
				          file.get_path(),
				          ret.get_path());
			}

			return ret;
		}

		private string target_from_make(File makefile,
		                                File source) throws SpawnError,
		                                                    RegexError,
		                                                    CompileArgsError
		{
			File wd = makefile.get_parent();
			string basen = source.get_basename();

			int idx = basen.last_index_of_char('.');
			string noext;

			if (idx >= 0)
			{
				noext = basen.substring(0, idx);
			}
			else
			{
				noext = basen;
			}

			string[] args = new string[] {
				"make",
				"-p",
				"-n",
				null
			};

			string outstr;

			/* Spawn make to find out which target has the source as a
			   dependency */
			Process.spawn_sync(wd.get_path(),
			                   args,
			                   null,
			                   SpawnFlags.SEARCH_PATH |
			                   SpawnFlags.STDERR_TO_DEV_NULL,
			                   null,
			                   out outstr);

			/* Scan the output to find the target */
			string prefreg = "^([^:]*(%s\\.(o|lo)))$".printf(Regex.escape_string(noext));
			string preflessreg = "^[a-z]+$";

			string reg = "^([^:\n]*):.*%s".printf(Regex.escape_string(basen));

			Regex regex = new Regex(reg, RegexCompileFlags.MULTILINE);
			MatchInfo info;

			if (regex.match(outstr, 0, out info))
			{
				Regex preg = new Regex(prefreg);
				Regex lreg = new Regex(preflessreg);
				string ?lastmatch = null;

				while (true)
				{
					string target = info.fetch(1);

					if (preg.match(target))
					{
						return target;
					}
					else if (lreg.match(target))
					{
						lastmatch = target;
					}

					if (!info.next())
					{
						break;
					}
				}

				if (lastmatch != null)
				{
					return lastmatch;
				}
			}

			throw new CompileArgsError.MISSING_TARGET(
				"Could not find make target for %s".printf(basen));
		}

		private string resolve_relative(File   makefile,
		                                File   source,
		                                string path)
		{
			if (Path.is_absolute(path))
			{
				return path;
			}

			File ret = makefile.get_parent().resolve_relative_path(path);
			return ret.get_path();
		}

		private string[] filter_flags(File     makefile,
		                              File     source,
		                              string[] args)
		{
			bool inexpand = false;
			int i = 0;
			ArrayList<string> ret = new ArrayList<string>();

			/* Keep only those flags that are interesting:
			 * -I...: include directories
			 * -D...: defines
			 * -W...: warnings
			 * -f...: compiler flags
			 */

			while (i < args.length)
			{
				string a = args[i];
				++i;

				if (a.index_of_char('`') != -1)
				{
					inexpand = !inexpand;
					continue;
				}

				if (inexpand)
				{
					continue;
				}

				// Check if it's some kind of flag
				if (a[0] != '-')
				{
					continue;
				}

				// Then see if it's a flag we understand
				switch (a[1])
				{
					case 'I':
						// Resolve relative arguments here
						if (a[2] != '\0')
						{
							ret.add("-I");
							ret.add(resolve_relative(makefile, source, a.substring(2)));
						}
						else if (i < args.length)
						{
							ret.add("-I");
							ret.add(resolve_relative(makefile, source, args[i]));
							++i;
						}
					break;
					case 'D':
					case 'f':
					case 'W':
						Log.debug("gcc flag: `%s'", a);

						// Append the flag
						ret.add(a);

						// If it has no embedded argument, then also add the argument
						if (a[2] == '\0' && i < args.length)
						{
							ret.add(args[i]);
							++i;
						}
					break;
				}
			}

			return ret.to_array();
		}

		private string[] ?flags_from_target(File   makefile,
		                                    File   source,
		                                    string target) throws SpawnError,
		                                                          CompileArgsError,
		                                                          ShellError
		{
			/* Fake make to build the target and extract the flags */
			string relsource = makefile.get_parent().get_relative_path(source);

			string fakecc = "__GCP_COMPILE_ARGS__";

			string[] args = new string[] {
				"make",
				"-s",
				"-i",
				"-n",
				"-W",
				relsource,
				"V=1",
				"CC=" + fakecc,
				"CXX=" + fakecc,
				target,
				null
			};

			string outstr;

			Process.spawn_sync(makefile.get_parent().get_path(),
			                   args,
			                   null,
			                   SpawnFlags.SEARCH_PATH |
			                   SpawnFlags.STDERR_TO_DEV_NULL,
			                   null,
			                   out outstr);

			/* Extract args */
			int idx = outstr.last_index_of(fakecc);

			if (idx < 0)
			{
				throw new CompileArgsError.MISSING_MAKE_OUTPUT("Make output did not contain flags");
			}

			string[] retargs;
			string[] parts = outstr.substring(idx + fakecc.length).split("\n");

			Shell.parse_argv(parts[0], out retargs);

			/* Copy only some of the flags that we are actually interested in */
			return filter_flags(makefile, source, retargs);
		}

		private async void makefile_changed_async(Makefile makefile)
		{
			ThreadFunc<void *> func = () => {
				foreach (File file in makefile.sources)
				{
					find_for_makefile(makefile.file, file);
				}

				return null;
			};

			try
			{
				Thread.create<void *>(func, false);
				yield;
			}
			catch
			{
			}
		}

		private void on_makefile_changed(Makefile makefile)
		{
			makefile_changed_async.begin(makefile);
		}

		private void find_for_makefile(File makefile, File file)
		{
			string target;
			string[] args = {};

			try
			{
				target = target_from_make(makefile, file);

				Log.debug("Makefile make target for `%s': `%s'",
				          file.get_path(),
				          target);

				args = flags_from_target(makefile, file, target);

				// Note: this is a hack but it seems clang 2.8 will not properly
				// add its default include search directories
				args += "-I";
				args += "/usr/lib/clang/%s/include".printf(Gcp.Config.LLVM_VERSION);

				Log.debug("Compile flags for `%s': `%s'",
				          file.get_path(),
				          string.joinv(", ", args));
			}
			catch (Error e)
			{
				stderr.printf("Makefile error: %s\n", e.message);
			}

			lock(d_makefileCache)
			{
				lock(d_argsCache)
				{
					if (d_argsCache.has_key(file))
					{
						d_argsCache[file].args = args;
					}
					else
					{
						Cache c = new Cache(file, makefile, args);
						d_argsCache[file] = c;
					}

					if (!d_makefileCache.has_key(makefile))
					{
						Makefile m = new Makefile(makefile);
						m.add(file);

						m.changed.connect(on_makefile_changed);
						d_makefileCache[makefile] = m;
					}
				}
			}

			changed_in_idle(file);
		}

		private void changed_in_idle(File file)
		{
			Idle.add(() => {
				arguments_changed(file);
				return false;
			});
		}

		private async void find_async(File file)
		{
			ThreadFunc<void *> func = () => {
				File ?makefile = null;

				try
				{
					makefile = makefile_for(file);
				}
				catch (Error e)
				{
					makefile = null;
				}

				if (makefile == null)
				{
					Cache c = new Cache(file, null, new string[] {});
					d_argsCache[file] = c;

					changed_in_idle(file);
					return null;
				}

				find_for_makefile(makefile, file);

				lock(d_makefileCache)
				{
					if (d_makefileCache.has_key(file))
					{
						d_makefileCache[makefile].add(file);
					}
				}

				return null;
			};

			try
			{
				Thread.create<void *>(func, false);
				yield;
			}
			catch
			{
			}
		}

		public new string[]? get(File file)
		{
			string[] ?ret = null;

			lock(d_argsCache)
			{
				if (d_argsCache.has_key(file))
				{
					ret = d_argsCache[file].args;
				}
				else
				{
					monitor(file);
				}
			}

			return ret;
		}

		public void monitor(File file)
		{
			bool hascache;

			lock(d_argsCache)
			{
				hascache = d_argsCache.has_key(file);
			}

			if (hascache)
			{
				arguments_changed(file);
			}
			else
			{
				find_async.begin(file, (source, res) => find_async.end(res));
			}
		}

		public void remove_monitor(File file)
		{
			lock(d_argsCache)
			{
				if (d_argsCache.has_key(file))
				{
					Cache c = d_argsCache[file];

					lock (d_makefileCache)
					{
						if (d_makefileCache.has_key(c.makefile))
						{
							Makefile m = d_makefileCache[c.makefile];

							if (m.remove(file))
							{
								d_makefileCache.unset(c.makefile);
							}
						}
					}

					d_argsCache.unset(file);
				}
			}
		}
	}
}

/* vi:ex:ts=4 */
