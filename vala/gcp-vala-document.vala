using Gtk;

namespace Gcp.Vala{
  public class Diagnostic : Vala.Report {
    public weak SourceView source_view { private set; get; }
    private Gcp.SourceIndex diags;
    
    public Diagnostic (SourceView source_view) {
      this.source_view = source_view;
    }
    
    public void set_diags(Gcp.SourceIndex diags){
      this.diags = diags;
    }
    
    public override void note (Vala.SourceReference? source, string message) {
      if (!enable_warnings) { return; }
      if (source != null){
        diags.add(new Gcp.Diagnostic(Gcp.DiagnosticSeverity.WARNING,
                                         source.get_begin(),
                                         new SourceRange(),
                                         new Fixit(),
                                         message));
      }
    }
    
    public override void depr (Vala.SourceReference? source, string message) {
      if (!enable_warnings) { return; }
      if (source != null){
        diags.add(new Gcp.Diagnostic(Gcp.DiagnosticSeverity.WARNING,
                                         source.get_begin(),
                                         new SourceRange(),
                                         new Fixit(),
                                         message));
      }
    }
    
    public override void warn (Vala.SourceReference? source, string message) {
      if (!enable_warnings) { return; }
      if (source != null){
        diags.add(new Gcp.Diagnostic(Gcp.DiagnosticSeverity.WARNING,
                                         source.get_begin(),
                                         new SourceRange(),
                                         new Fixit(),
                                         message));
      }
    }
    
    public override void err (Vala.SourceReference? source, string message) {
      if (!enable_warnings) { return; }
      if (source != null){
        diags.add(new Gcp.Diagnostic(Gcp.DiagnosticSeverity.ERROR,
                                         source.get_begin(),
                                         new SourceRange(),
                                         new Fixit(),
                                         message));
      }
    }       
  }

  public class ParseThread{
    private string? source_file;
    private string? source_contents;
    private Diagnostic reporter;
    
    public ParseThread(Gcp.Document doc){
      if (doc.location != null){
			  this.source_file = doc.location.get_path();
		  }
		  
		  if (this.source_file == null){
		    this.source_file = "<unknown>";
		  }
		  
		  TextIter start;
		  TextIter end;

		  doc.get_bounds(out start, out end);
		  this.source_contents = d_doc.get_text(start, end, true);
    }
    
    construct{
      this.source_file = null;
    }
    
    
    public async void start_parse_thread(){
      ThreadFunc<void *> run = () => {
        Vala.CodeContext context = new Vala.CodeContext ();
        context.report = reporter;
        Vala.CodeContext.push (context);
      
        Vala.SourceFile vala_sf = new Vala.SourceFile (context, this.source_file, true);
        context.add_source_file (vala_sf);
      
        Vala.Parser ast = new Vala.Parser();
        ast.parse(context);
        
        Vala.CodeContext.pop ();
		  };
		  try
		  {
			  Thread.create<void *>(run, false);
			  yield;
		  }
		  catch{ }
    }
  }
  
  public class Document: Gcp.Document, Gcp.DiagnosticSupport{
    private DiagnosticTags d_tags;
    private SourceIndex d_diagnostics;
    private Mutex d_diagnosticsLock;
    private uint reparse_timeout;
    private ParserThread reparse_thread;
    
    public Document(Gedit.Document document){
		  Object(document: document);
	  }    
    
    construct{
	    this.d_diagnostics = new SourceIndex();
	    this.d_diagnosticsLock = new Mutex();
	    this.reparse_timeout = 0;
	  }
	  
	  public void set_diagnostic_tags(DiagnosticTags tags){
		  d_tags = tags;
		}
	 
	  public DiagnosticTags get_diagnostic_tags(){
		  return d_tags;
	  }
	  
	  public void update(){
	    if (this.reparse_timeout != 0){
	      Source.remove(this.reparse_timeout);
	    }
	    
		  this.reparse_timeout = Timeout.add(500, () => {this.reparse_timeout = 0; on_reparse_timeout(); return false;});
		  
	  }
	  
	  public SourceIndex begin_diagnostics(){
		  d_diagnosticsLock.lock();
		  return d_diagnostics;
	  }

	  public void end_diagnostics(){
		  d_diagnosticsLock.unlock();
	  }
	  
	  public void on_reparse_timeout(){
	     this.reparse_thread = new ParseThread(this);
	     this.reparse_thread.start_parse_thread();
	  }
	  
	   
	}
}
