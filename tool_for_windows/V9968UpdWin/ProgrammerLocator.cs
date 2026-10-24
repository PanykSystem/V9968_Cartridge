// -----------------------------------------------------------------------------
//	V9968UPD for Windows
//	Copyright (C)2026 HRA!
//	MIT License
// -----------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace V9968UpdWin
{
	internal static class ProgrammerLocator
	{
		public const string ExeName = "programmer_cli.exe";

		private static string SettingsFile
		{
			get {
				return Path.Combine(
					Environment.GetFolderPath( Environment.SpecialFolder.LocalApplicationData ),
					"V9968UpdWin", "programmer_cli_path.txt" );
			}
		}

		public static bool IsValid( string path )
		{
			return !string.IsNullOrWhiteSpace( path )
				&& File.Exists( path )
				&& string.Equals( Path.GetFileName( path ), ExeName, StringComparison.OrdinalIgnoreCase );
		}

		public static string Find()
		{
			string saved = LoadSaved();
			if( IsValid( saved ) ) {
				return saved;
			}
			foreach( string candidate in Candidates() ) {
				if( IsValid( candidate ) ) {
					return candidate;
				}
			}
			return null;
		}

		public static void Save( string path )
		{
			try {
				Directory.CreateDirectory( Path.GetDirectoryName( SettingsFile ) );
				File.WriteAllText( SettingsFile, path );
			}
			catch( Exception ) {
				// The path is only a convenience cache.
			}
		}

		private static string LoadSaved()
		{
			try {
				return File.Exists( SettingsFile ) ? File.ReadAllText( SettingsFile ).Trim() : null;
			}
			catch( Exception ) {
				return null;
			}
		}

		private static IEnumerable<string> Candidates()
		{
			string pathEnv = Environment.GetEnvironmentVariable( "PATH" ) ?? "";
			foreach( string dir in pathEnv.Split( Path.PathSeparator ) ) {
				string trimmed = dir.Trim().Trim( '"' );
				if( trimmed.Length > 0 ) {
					yield return SafeCombine( trimmed, ExeName );
				}
			}

			var roots = new List<string>();
			foreach( DriveInfo drive in DriveInfo.GetDrives() ) {
				if( drive.DriveType == DriveType.Fixed ) {
					roots.Add( drive.RootDirectory.FullName );
				}
			}
			roots.Add( Environment.GetFolderPath( Environment.SpecialFolder.ProgramFiles ) );
			roots.Add( Environment.GetFolderPath( Environment.SpecialFolder.ProgramFilesX86 ) );

			foreach( string root in roots.Where( r => !string.IsNullOrEmpty( r ) ).Distinct( StringComparer.OrdinalIgnoreCase ) ) {
				foreach( string gowinName in new[] { "Gowin", "GOWIN" } ) {
					string gowin = SafeCombine( root, gowinName );
					if( gowin == null || !Directory.Exists( gowin ) ) {
						continue;
					}
					// Prefer the newest installation, e.g. C:\Gowin\Gowin_V1.9.12.03_x64.
					string[] versions;
					try {
						versions = Directory.GetDirectories( gowin ).OrderByDescending( d => d, StringComparer.OrdinalIgnoreCase ).ToArray();
					}
					catch( Exception ) {
						versions = new string[ 0 ];
					}
					foreach( string version in versions ) {
						yield return Path.Combine( version, "Programmer", "bin", ExeName );
					}
					yield return Path.Combine( gowin, "Programmer", "bin", ExeName );
				}
			}
		}

		private static string SafeCombine( string a, string b )
		{
			try {
				return Path.Combine( a, b );
			}
			catch( ArgumentException ) {
				return null;
			}
		}
	}
}
