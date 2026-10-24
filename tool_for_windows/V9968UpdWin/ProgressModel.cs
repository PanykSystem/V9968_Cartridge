// -----------------------------------------------------------------------------
//	V9968UPD for Windows
//	Copyright (C)2026 HRA!
//	MIT License
// -----------------------------------------------------------------------------
using System;
using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;

namespace V9968UpdWin
{
	internal enum CliPhase
	{
		Starting,
		Erasing,
		Programming,
		Verifying,
	}

	// Converts programmer_cli output of one run into a monotonic overall percentage.
	// When the CLI prints no percentage, the value creeps up with time inside the current phase.
	internal sealed class ProgressModel
	{
		private static readonly Regex PercentPattern = new Regex( @"(\d{1,3}(?:\.\d+)?)\s*%" );

		private readonly object _sync = new object();
		private readonly Stopwatch _phaseWatch = new Stopwatch();
		private double _stepStart;
		private double _stepSpan;
		private double _timeScale = 1.0;
		private double _phasePercent;
		private double _overall;

		public CliPhase Phase { get; private set; }

		public void BeginStep( double start, double span, double timeScale )
		{
			lock( _sync ) {
				_stepStart = start;
				_stepSpan = span;
				_timeScale = Math.Max( 0.05, timeScale );
				SetPhase( CliPhase.Starting );
				_overall = Math.Max( _overall, start );
			}
		}

		public void Reset()
		{
			lock( _sync ) {
				_overall = 0;
				_stepStart = 0;
				_stepSpan = 0;
				SetPhase( CliPhase.Starting );
			}
		}

		public void Complete( double value )
		{
			lock( _sync ) {
				_overall = Math.Max( _overall, value );
			}
		}

		public void OnLine( string line )
		{
			lock( _sync ) {
				if( line.IndexOf( "Verif", StringComparison.OrdinalIgnoreCase ) >= 0 ) {
					AdvanceTo( CliPhase.Verifying );
				}
				else if( line.IndexOf( "Programming", StringComparison.OrdinalIgnoreCase ) >= 0
					|| line.IndexOf( "Writing", StringComparison.OrdinalIgnoreCase ) >= 0 ) {
					AdvanceTo( CliPhase.Programming );
				}
				else if( line.IndexOf( "Erasing", StringComparison.OrdinalIgnoreCase ) >= 0 ) {
					AdvanceTo( CliPhase.Erasing );
				}

				Match m = PercentPattern.Match( line );
				double value;
				if( m.Success && double.TryParse( m.Groups[ 1 ].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out value ) ) {
					_phasePercent = Math.Max( _phasePercent, Math.Min( 100.0, value ) );
				}
			}
		}

		public double Current
		{
			get {
				lock( _sync ) {
					double phaseStart, phaseSpan, tau;
					switch( Phase ) {
					case CliPhase.Erasing:		phaseStart = 0.05; phaseSpan = 0.20; tau = 8.0;  break;
					case CliPhase.Programming:	phaseStart = 0.25; phaseSpan = 0.50; tau = 25.0; break;
					case CliPhase.Verifying:	phaseStart = 0.75; phaseSpan = 0.25; tau = 20.0; break;
					default:					phaseStart = 0.00; phaseSpan = 0.05; tau = 3.0;  break;
					}
					double seconds = _phaseWatch.Elapsed.TotalSeconds;
					double byTime = 0.9 * ( 1.0 - Math.Exp( -seconds / ( tau * _timeScale ) ) );
					double fraction = Math.Max( byTime, _phasePercent / 100.0 );
					double value = _stepStart + _stepSpan * ( phaseStart + phaseSpan * Math.Min( 1.0, fraction ) );
					_overall = Math.Max( _overall, Math.Min( value, _stepStart + _stepSpan ) );
					return _overall;
				}
			}
		}

		private void AdvanceTo( CliPhase phase )
		{
			if( phase > Phase ) {
				SetPhase( phase );
			}
		}

		private void SetPhase( CliPhase phase )
		{
			Phase = phase;
			_phasePercent = 0;
			_phaseWatch.Restart();
		}
	}
}
